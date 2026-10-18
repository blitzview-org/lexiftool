--------------------------------------------------------------------------------
-- File:         lexiftool/Pentax.lua
-- Ported from:  lib/Image/ExifTool/Pentax.pm
--
-- Description:  Pentax/Asahi EXIF maker notes tags
--
-- Revisions:    11/25/2003 - P. Harvey Created
--               02/10/2004 - P. Harvey Completely re-done
--               02/16/2004 - W. Smith Updated (see ref 3)
--               11/10/2004 - P. Harvey Added support for Asahi cameras
--               01/10/2005 - P. Harvey Added LensType with values from ref 4
--               03/30/2005 - P. Harvey Added new tags from ref 5
--               10/04/2005 - P. Harvey Added MOV tags
--               10/22/2007 - P. Harvey Got my new K10D! (more new tags to decode)
--               11/03/2010 - P. Harvey Got my new K-5! (a gold mine of new tags to discover!)
--
-- References:   1) Image::MakerNotes::Pentax
--               2) http://johnst.org/sw/exiftags/ (Asahi cameras)
--               3) Wayne Smith private communication (Optio 550)
--               4) http://kobe1995.jp/~kaz/astro/istD.html
--               5) John Francis (http://www.panix.com/~johnf/raw/index.html) (ist-D/ist-DS)
--               6) http://www.cybercom.net/~dcoffin/dcraw/
--               7) Douglas O'Brien private communication (*istD, K10D)
--               8) Denis Bourez private communication
--               9) Kazumichi Kawabata private communication
--              10) David Buret private communication (*istD)
--              11) http://forums.dpreview.com/forums/read.asp?forum=1036&message=17465929
--              12) Derby Chang private communication
--              13) http://homepage3.nifty.com/kamisaka/makernote/makernote_pentax.htm (2007/02/28)
--              14) Ger Vermeulen private communication (Optio S6)
--              15) Barney Garrett private communication (Samsung GX-1S)
--              16) Axel Kellner private communication (K10D)
--              17) Cvetan Ivanov private communication (K100D)
--              18) http://gvsoft.homedns.org/exif/makernote-pentax-type3.html
--              19) Dave Nicholson private communication (K10D)
--              20) Bogdan and yeryry (http://www.cpanforum.com/posts/8037)
--              21) Peter (*istD, http://www.cpanforum.com/posts/8078)
--              22) Bozi (K10D, http://www.cpanforum.com/posts/8480)
--              23) Akos Szalkai (https://rt.cpan.org/Ticket/Display.html?id=43743)
--              24) Albert Bogner private communication
--              26) https://exiftool.org/forum/index.php/topic,3444.0.html
--              27) https://exiftool.org/forum/index.php/topic,3833.0.html
--              28) Klaus Homeister https://exiftool.org/forum/index.php/topic,4803.0.html
--              29) Louis Granboulan private communication (K-5II)
--              30) https://exiftool.org/forum/index.php?topic=5433
--              31) Andras Salamon private communication (K-70)
--              IB) Iliah Borg private communication (LibRaw)
--              JD) Jens Duttke private communication
--              NJ) Niels Kristian Bech Jensen private communication
--              KG) Karsten Gieselmann private communication
--
-- Notes:        See POD documentation at the bottom of this file
--
-- Port notes:   read-only port.  Every upstream tag table is carried with its
--               full tag set (`Main`, `SRInfo`, `SRInfo2`, `FaceInfo`,
--               `AWBInfo`, `TimeInfo`, `LensCorr`, `CameraSettings`,
--               `CameraSettingsUnknown`, `AEInfo`, `AEInfo2`, `AEInfo3`,
--               `AEInfoUnknown`, `LensRec`, `LensInfo`, `LensInfo2`-`5`,
--               `LensData`, `FlashInfo`, `FlashInfoUnknown`, `CameraInfo`,
--               `BatteryInfo`, `AFInfo`, `CAFPointInfo`, `KelvinWB`,
--               `ColorInfo`, `EVStepInfo`, `ShotInfo`, `FacePos`, `FaceSize`,
--               `FilterInfo`, `LevelInfo`, `LevelInfoK3III`, `FaceInfoK3III`,
--               `AFInfoK3III`, `WBLevels`, `LensInfoQ`, `PixelShiftInfo`,
--               `AFPointInfo`, `TempInfo`, `UnknownInfo`, `Type2`, `Type4`,
--               `MOV`, `AVI`, `S1`, `Junk`, `PXTH`, `PENT`, `Junk2`), as are
--               the `%colorTemp`/`%kelvinWB`/`%lensCode`/`%digitalFilter`
--               defaults hashes (conventions.md §2 helpers), `%filterSettings`
--               and `@k3iiiAF`, and the subs `PentaxEv`, `PentaxEvInv`,
--               `CryptShutterCount`, `DecodeAFPoints`, `PrintFilter`,
--               `AFPointNamesK3III`, `AFPointValuesK3III` and `AFAreasK3III`.
--               The large lookups `pentaxModelID`, `pentaxCities` and
--               `pentaxLensTypes` are carried in full.  Every
--               conditional list in `Main` carries all its upstream
--               branches, in upstream order.
--               `PrintFilter`'s reverse (write) direction is not ported.
--               `AVI`/`PENT`/`PXTH`
--               are exercised by `Pentax.t` test 4.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local Writer = require('lexiftool.Writer')
local perl = require('lexiftool.perl')
local matches, unpack_, pack_ = perl.matches, perl.unpack, perl.pack
local subst = perl.subst
local sprintf = perl.sprintf
local tsort = perl.tsort
local str = perl.str
local Exif = require('lexiftool.Exif')
local GPS = require('lexiftool.GPS')
local HP = require('lexiftool.HP')

local Pentax = {}

-- common attributes for writable BinaryData directories
local binaryDataAttrs = function(t)
    for k, v in pairs {
        PROCESS_PROC = ExifTool.ProcessBinaryData,
        WRITE_PROC = Writer.WriteBinaryData,
        CHECK_PROC = Writer.CheckBinaryData,
        WRITABLE = 1,
        FIRST_ENTRY = 0,
    } do t[k] = v end
    return t
end

-- Pentax model ID codes - PH
local pentaxModelID = {
    [0x0000d] = 'Optio 330/430',
    [0x12926] = 'Optio 230',
    [0x12958] = 'Optio 330GS',
    [0x12962] = 'Optio 450/550',
    [0x1296c] = 'Optio S',
    [0x12971] = 'Optio S V1.01',
    [0x12994] = '*ist D',
    [0x129b2] = 'Optio 33L',
    [0x129bc] = 'Optio 33LF',
    [0x129c6] = 'Optio 33WR/43WR/555',
    [0x129d5] = 'Optio S4',
    [0x12a02] = 'Optio MX',
    [0x12a0c] = 'Optio S40',
    [0x12a16] = 'Optio S4i',
    [0x12a34] = 'Optio 30',
    [0x12a52] = 'Optio S30',
    [0x12a66] = 'Optio 750Z',
    [0x12a70] = 'Optio SV',
    [0x12a75] = 'Optio SVi',
    [0x12a7a] = 'Optio X',
    [0x12a8e] = 'Optio S5i',
    [0x12a98] = 'Optio S50',
    [0x12aa2] = '*ist DS',
    [0x12ab6] = 'Optio MX4',
    [0x12ac0] = 'Optio S5n',
    [0x12aca] = 'Optio WP',
    [0x12afc] = 'Optio S55',
    [0x12b10] = 'Optio S5z',
    [0x12b1a] = '*ist DL',
    [0x12b24] = 'Optio S60',
    [0x12b2e] = 'Optio S45',
    [0x12b38] = 'Optio S6',
    [0x12b4c] = 'Optio WPi', -- #13
    [0x12b56] = 'BenQ DC X600',
    [0x12b60] = '*ist DS2',
    [0x12b62] = 'Samsung GX-1S',
    [0x12b6a] = 'Optio A10',
    [0x12b7e] = '*ist DL2',
    [0x12b80] = 'Samsung GX-1L',
    [0x12b9c] = 'K100D',
    [0x12b9d] = 'K110D',
    [0x12ba2] = 'K100D Super', -- #JD
    [0x12bb0] = 'Optio T10/T20',
    [0x12be2] = 'Optio W10',
    [0x12bf6] = 'Optio M10',
    [0x12c1e] = 'K10D',
    [0x12c20] = 'Samsung GX10',
    [0x12c28] = 'Optio S7',
    [0x12c2d] = 'Optio L20',
    [0x12c32] = 'Optio M20',
    [0x12c3c] = 'Optio W20',
    [0x12c46] = 'Optio A20',
    [0x12c78] = 'Optio E30',
    [0x12c7d] = 'Optio E35',
    [0x12c82] = 'Optio T30',
    [0x12c8c] = 'Optio M30',
    [0x12c91] = 'Optio L30',
    [0x12c96] = 'Optio W30',
    [0x12ca0] = 'Optio A30',
    [0x12cb4] = 'Optio E40',
    [0x12cbe] = 'Optio M40',
    [0x12cc3] = 'Optio L40',
    [0x12cc5] = 'Optio L36',
    [0x12cc8] = 'Optio Z10',
    [0x12cd2] = 'K20D',
    [0x12cd4] = 'Samsung GX20', -- #8
    [0x12cdc] = 'Optio S10',
    [0x12ce6] = 'Optio A40',
    [0x12cf0] = 'Optio V10',
    [0x12cfa] = 'K200D',
    [0x12d04] = 'Optio S12',
    [0x12d0e] = 'Optio E50',
    [0x12d18] = 'Optio M50',
    [0x12d22] = 'Optio L50',
    [0x12d2c] = 'Optio V20',
    [0x12d40] = 'Optio W60',
    [0x12d4a] = 'Optio M60',
    [0x12d68] = 'Optio E60/M90',
    [0x12d72] = 'K2000',
    [0x12d73] = 'K-m',
    [0x12d86] = 'Optio P70',
    [0x12d90] = 'Optio L70',
    [0x12d9a] = 'Optio E70',
    [0x12dae] = 'X70',
    [0x12db8] = 'K-7',
    [0x12dcc] = 'Optio W80',
    [0x12dea] = 'Optio P80',
    [0x12df4] = 'Optio WS80',
    [0x12dfe] = 'K-x',
    [0x12e08] = '645D',
    [0x12e12] = 'Optio E80',
    [0x12e30] = 'Optio W90',
    [0x12e3a] = 'Optio I-10',
    [0x12e44] = 'Optio H90',
    [0x12e4e] = 'Optio E90',
    [0x12e58] = 'X90',
    [0x12e6c] = 'K-r',
    [0x12e76] = 'K-5',
    [0x12e8a] = 'Optio RS1000/RS1500',
    [0x12e94] = 'Optio RZ10',
    [0x12e9e] = 'Optio LS1000',
    [0x12ebc] = 'Optio WG-1 GPS',
    [0x12ed0] = 'Optio S1',
    [0x12ee4] = 'Q',
    [0x12ef8] = 'K-01',
    [0x12f0c] = 'Optio RZ18',
    [0x12f16] = 'Optio VS20',
    [0x12f2a] = 'Optio WG-2 GPS',
    [0x12f48] = 'Optio LS465',
    [0x12f52] = 'K-30',
    [0x12f5c] = 'X-5',
    [0x12f66] = 'Q10',
    [0x12f70] = 'K-5 II',
    [0x12f71] = 'K-5 II s', -- #forum4515
    [0x12f7a] = 'Q7',
    [0x12f84] = 'MX-1',
    [0x12f8e] = 'WG-3 GPS',
    [0x12f98] = 'WG-3',
    [0x12fa2] = 'WG-10',
    [0x12fb6] = 'K-50',
    [0x12fc0] = 'K-3', -- #29
    [0x12fca] = 'K-500',
    [0x12fe8] = 'WG-4', -- (Ricoh)
    [0x12fde] = 'WG-4 GPS', -- (Ricoh)
    [0x13006] = 'WG-20', -- (Ricoh)
    [0x13010] = '645Z',
    [0x1301a] = 'K-S1',
    [0x13024] = 'K-S2', -- #29 (Ricoh)
    [0x1302e] = 'Q-S1',
    [0x13056] = 'WG-30', -- (Ricoh)
    [0x1307e] = 'WG-30W', -- (Ricoh)
    [0x13088] = 'WG-5 GPS', -- (Ricoh)
    [0x13092] = 'K-1', -- #IB (Ricoh)
    [0x1309c] = 'K-3 II', -- #29 (Ricoh)
    [0x131f0] = 'WG-M2', -- (Ricoh)
    [0x1320e] = 'GR III', -- (Ricoh)
    [0x13222] = 'K-70', -- #29 (Ricoh)
    [0x1322c] = 'KP', -- #29 (Ricoh)
    [0x13240] = 'K-1 Mark II', -- (Ricoh)
    [0x13254] = 'K-3 Mark III', -- #IB (Ricoh)
    [0x13290] = 'WG-70', -- (Ricoh)
    [0x1329a] = 'GR IIIx', -- (Ricoh)
    [0x132b8] = 'KF', -- #github322 (Ricoh)
    [0x132d6] = 'K-3 Mark III Monochrome', -- #github226 (Ricoh)
    [0x132e0] = 'GR IV', -- #github347 (Ricoh)
    [0x13330] = 'GR IV Monochrome', -- #forum17904 (Ricoh)
}

-- Pentax city codes - (PH, Optio WP)
local pentaxCities = {
    [0] = 'Pago Pago',
    [1] = 'Honolulu',
    [2] = 'Anchorage',
    [3] = 'Vancouver',
    [4] = 'San Francisco',
    [5] = 'Los Angeles',
    [6] = 'Calgary',
    [7] = 'Denver',
    [8] = 'Mexico City',
    [9] = 'Chicago',
    [10] = 'Miami',
    [11] = 'Toronto',
    [12] = 'New York',
    [13] = 'Santiago',
    [14] = 'Caracus',
    [15] = 'Halifax',
    [16] = 'Buenos Aires',
    [17] = 'Sao Paulo',
    [18] = 'Rio de Janeiro',
    [19] = 'Madrid',
    [20] = 'London',
    [21] = 'Paris',
    [22] = 'Milan',
    [23] = 'Rome',
    [24] = 'Berlin',
    [25] = 'Johannesburg',
    [26] = 'Istanbul',
    [27] = 'Cairo',
    [28] = 'Jerusalem',
    [29] = 'Moscow',
    [30] = 'Jeddah',
    [31] = 'Tehran',
    [32] = 'Dubai',
    [33] = 'Karachi',
    [34] = 'Kabul',
    [35] = 'Male',
    [36] = 'Delhi',
    [37] = 'Colombo',
    [38] = 'Kathmandu',
    [39] = 'Dacca',
    [40] = 'Yangon',
    [41] = 'Bangkok',
    [42] = 'Kuala Lumpur',
    [43] = 'Vientiane',
    [44] = 'Singapore',
    [45] = 'Phnom Penh',
    [46] = 'Ho Chi Minh',
    [47] = 'Jakarta',
    [48] = 'Hong Kong',
    [49] = 'Perth',
    [50] = 'Beijing',
    [51] = 'Shanghai',
    [52] = 'Manila',
    [53] = 'Taipei',
    [54] = 'Seoul',
    [55] = 'Adelaide',
    [56] = 'Tokyo',
    [57] = 'Guam',
    [58] = 'Sydney',
    [59] = 'Noumea',
    [60] = 'Wellington',
    [61] = 'Auckland',
    [62] = 'Lima',
    [63] = 'Dakar',
    [64] = 'Algiers',
    [65] = 'Helsinki',
    [66] = 'Athens',
    [67] = 'Nairobi',
    [68] = 'Amsterdam',
    [69] = 'Stockholm',
    [70] = 'Lisbon', -- #14
    [71] = 'Copenhagen', -- #NJ
    [72] = 'Warsaw',
    [73] = 'Prague',
    [74] = 'Budapest',
}

-- decrypt version numbers stored as 4 encrypted bytes (upstream %pentaxFirmwareID)
local PrintFilter  -- predeclaration, see below for implementation

-- digital filter tag information (ref PH, K-5)
-- (also see %filterSettings below for decoding of filter parameters)
-- (upstream is the hash %digitalFilter, spread into a tag entry;
--  conventions.md §2 turns a spread hash into a helper)
local function digitalFilter(t)
    t.Format = 'undef[17]'
    t.RawConv = function(self, val)
        if matches(str(val), [[^\0]]) == nil or perl.truthy(self:Options('Unknown')) then
            local out = {}
            local b = { unpack_('Cc*', val) }
            for i = 1, #b do out[i] = str(b[i]) end
            return table.concat(out, ' ')
        end
        return nil
    end
    t.SeparateTable = 'DigitalFilter'
    t.ValueConvInv = function(_self, val)
        if perl.str(val) == '0' then return string.rep('\0', 17) end
        val = pack_('Cc*', table.unpack(perl.findAll(val, [[[-+]?\d+]])))
        if #val ~= 17 then error("Expecting 17 values\n", 0) end
        return val
    end
    t.PrintConv = {
        -- this routine actually converts all values
        OTHER = function(val, inv, conv) return PrintFilter(val, inv, conv) end,
        [0] = 'Off',
        [1] = 'Base Parameter Adjust',
        [2] = 'Soft Focus',
        [3] = 'High Contrast',
        [4] = 'Color Filter',
        [5] = 'Extract Color',
        [6] = 'Monochrome',
        [7] = 'Slim',
        [9] = 'Fisheye',
        [10] = 'Toy Camera',
        [11] = 'Retro',
        [12] = 'Pastel',
        [13] = 'Water Color',
        [14] = 'HDR',
        [16] = 'Miniature',
        [17] = 'Starburst',
        [18] = 'Posterization',
        [19] = 'Sketch Filter',
        [20] = 'Shading', -- (Q)
        [21] = 'Invert Color', -- (Q)
        [23] = 'Tone Expansion', -- #Forum5247
        [27] = 'Unicolor Bold', -- #31
        [28] = 'Bold Monochrome', -- #31
        [29] = 'Replace Color', -- #31
        [254] = 'Custom Filter',
    }
    return t
end

-- digital filter setting names and conversions (ref PH, K-5)
-- Note: names must be unique for writing
local filterSettings = {
    [1]  = { 'Brightness', '%+d' },    -- BPA (-8-+8)
    [2]  = { 'Saturation', '%+d' },    -- BPA (-3-+3)
    [3]  = { 'Hue', '%+d' },           -- BPA (-3-+3)
    [4]  = { 'Contrast', '%+d' },      -- BPA (-3-+3)
    [5]  = { 'Sharpness', '%+d' },     -- BPA (-3-+3)
    [6]  = { 'SoftFocus', '%d' },      -- Soft Focus/Custom (1-3)
    [7]  = { 'ShadowBlur',    { [0]='Off',[1]='On' } }, -- Soft Focus
    [8]  = { 'HighContrast', '%d' },   -- High Contrast/Custom (1-5)
    [9]  = { 'Color',         { [1]='Red',[2]='Magenta',[3]='Blue',[4]='Cyan',[5]='Green',[6]='Yellow' } }, -- Color Filter
    [10] = { 'Density',       { [1]='Light',[2]='Standard',[3]='Dark' } }, -- Color Filter
    [11] = { 'ExtractedColor',{ [0]='Off',[1]='Red',[2]='Magenta',[3]='Blue',[4]='Cyan',[5]='Green',[6]='Yellow' } }, -- Extract Color [x2]
    [12] = { 'ColorRange', '%+d' },    -- Extract Color [x2] (-2-+2)
    [13] = { 'FilterEffect',  { [0]='Off',[1]='Red',[2]='Green',[3]='Blue',[4]='Infrared' } }, -- Monochrome
    [14] = { 'ToningBA', '%+d' },      -- Monochrome (-3-+3)
    [15] = { 'InvertColor',   { [0]='Off',[1]='On' } }, -- Custom/Invert Color
    [16] = { 'Slim', '%+d' },          -- Slim (-8-+8)
    [17] = { 'EffectDensity', { [1]='Sparse',[2]='Normal',[3]='Dense' } }, -- Starburst
    [18] = { 'Size',          { [1]='Small',[2]='Medium',[3]='Large' } }, -- Starburst
    [19] = { 'Angle',         { [0]='0deg',[2]='30deg',[3]='45deg',[4]='60deg' } }, -- Starburst (1 is unused)
    [20] = { 'Fisheye',       { [1]='Weak',[2]='Medium',[3]='Strong' } }, -- Fisheye
    [21] = { 'DistortionType', '%d' }, -- Custom (1-3)
    [22] = { 'DistortionLevel',{ [0]='Off',[1]='Weak',[2]='Medium',[3]='Strong' } }, --Custom
    [23] = { 'ShadingType', '%d' },    -- Custom/Shading (1-6)
    [24] = { 'ShadingLevel', '%+d' },  -- Custom/Shading (-3-+3)
    [25] = { 'Shading', '%d' },        -- Toy Camera (1-3)
    [26] = { 'Blur',  '%d' },          -- Toy Camera (1-3)
    [27] = { 'ToneBreak',     { [0]='Off',[1]='Red',[2]='Green',[3]='Blue',[4]='Yellow' } }, -- Toy Camera/Custom
    [28] = { 'Toning', '%+d' },        -- Retro (-3-+3)
    [29] = { 'FrameComposite',{ [0]='None',[1]='Thin',[2]='Medium',[3]='Thick' } }, -- Retro
    [30] = { 'PastelStrength',{ [1]='Weak',[2]='Medium',[3]='Strong' } }, -- Pastel
    [31] = { 'Intensity', '%d' },      -- Water Color (1-3)
    [32] = { 'Saturation2',   { [0]='Off',[1]='Low',[2]='Medium',[3]='High' } }, -- Water Color
    [33] = { 'HDR',           { [1]='Weak',[2]='Medium',[3]='Strong' } }, -- HDR
    -- (34 missing)
    [35] = { 'FocusPlane', '%+d' },    -- Miniature (-3-+3)
    [36] = { 'FocusWidth',    { [1]='Narrow',[2]='Middle',[3]='Wide' } }, -- Miniature
    [37] = { 'PlaneAngle',    { [0]='Horizontal',[1]='Vertical',[2]='Positive slope',[3]='Negative slope' } }, -- Miniature
    [38] = { 'Blur2', '%d' },          -- Miniature (1-3)
    [39] = { 'Shape',         { [1]='Cross',[2]='Star',[3]='Snowflake',[4]='Heart',[5]='Note' } }, -- Starburst
    [40] = { 'Posterization', '%d' },  -- Posterization (1-5)
    [41] = { 'Contrast2',     { [1]='Low',[2]='Medium',[3]='High' } }, -- Sketch Filter
    [42] = { 'ScratchEffect', { [0]='Off',[1]='On' } }, -- Sketch Filter
    [45] = { 'ToneExpansion', { [1]='Low',[2]='Medium',[3]='High' } }, -- Tone Expansion (ref Forum5247)
    [47] = { 'UnicolorBold',  { [1]='Red',[2]='Magenta',[3]='Blue',[4]='Cyan',[5]='Green',[6]='Yellow' } }, --31 Unicolor Bold
    [48] = { 'BoldMonochrome', '%d' }, --31 Bold Monochrome (1-3)
    [49] = { 'OriginalColor', { [1]='Red',[2]='Magenta',[3]='Blue',[4]='Cyan',[5]='Green',[6]='Yellow' } }, --31 Replace Color
    [50] = { 'NewColor',      { [1]='Red',[2]='Magenta',[3]='Blue',[4]='Cyan',[5]='Green',[6]='Yellow' } }, --31 Replace Color
    [51] = { 'ColorScale', '%d' }, --31 Replace Color (1-5)
    [52] = { 'Toning2', '%+d' }, --31 Extract Color (-3-+3)
}

-- order of selectable K-3iii AF points.  The array looks like this:
--     B1 C1 E1 G1 I1 K1 L1
--  A3 B3 C3 E3 G3 I3 K3 L3 M3
--  A5 B5 C5 E5 G5 I5 K5 L5 M5
--  A7 B7 C7 E7 G7 I7 K7 L7 M7
--     B9 C9 E9 G9 I9 K9 L9
local k3iiiAF = {
    'C1', 'E1', 'G1', 'I1', 'K1', 'C3', 'E3', 'G3', 'I3', 'K3', 'C5', 'E5', 'G5',
    'I5', 'K5', 'C7', 'E7', 'G7', 'I7', 'K7', 'C9', 'E9', 'G9', 'I9', 'K9', 'A5', 'M5', 'B3',
    'L3', 'B5', 'L5', 'B7', 'L7', 'B1', 'L1', 'B9', 'L9', 'A3', 'M3', 'A7', 'M7',
    'D1', 'F1', 'H1', 'J1', 'D3', 'F3', 'H3', 'J3', 'D5', 'F5', 'H5', 'J5', 'D7',
    'F7', 'H7', 'J7', 'D9', 'F9', 'H9', 'J9', 'C2', 'E2', 'G2', 'I2', 'K2', 'C4',
    'E4', 'G4', 'I4', 'K4', 'C6', 'E6', 'G6', 'I6', 'K6', 'C8', 'E8', 'G8', 'I8',
    'K8', 'B2', 'L2', 'B4', 'L4', 'B6', 'L6', 'B8', 'L8', 'A1', 'M1', 'A2', 'M2',
    'A4', 'M4', 'A6', 'M6', 'A8', 'M8', 'A9', 'M9',
}

local pentaxFirmwareID = {
    ValueConv = function(_self, val)
        val = str(val)
        if #val ~= 4 then return val end
        local a, b, c, d = val:byte(1, 4)
        a, b, c, d = a ~ 0xff, b ~ 0xff, c ~ 0xff, d ~ 0xff
        return sprintf('%d %.2d %.2d %.2d', a, b, c, d)
    end,
    ValueConvInv = function(_self, val)
        local a = perl.findAll(val, [[\b\d+\b]])
        if #a ~= 4 then return val end
        for i = 1, #a do a[i] = (perl.int(a[i]) & 0xff) ~ 0xff end
        return pack_('C*', table.unpack(a))
    end,
    PrintConv = function(_self, val) return (str(val):gsub(' ', '.')) end,
    PrintConvInv = function(_self, val)
        if matches(val, [[^(\d+)\.(\d+)\.(\d+)\.(\d+)]]) then
            return (subst(val, [[^(\d+)\.(\d+)\.(\d+)\.(\d+)]], '$1 $2 $3 $4'))
        end
        return nil
    end,
}

-- (upstream is the hash %lensCode, spread into a tag entry; conventions.md §2
--  turns a spread hash into a helper that fills in the shared entries)
local function lensCode(t)
    t.Unknown = 1
    t.PrintConv = function(_self, val) return sprintf('0x%.2x', val) end
    t.PrintConvInv = function(_self, val) return perl.hex(val) end
    return t
end

-- conversions for ColorTemperature tags
-- (upstream is the hash %colorTemp, spread into a tag entry; conventions.md §2
--  turns a spread hash into a helper that fills in the shared entries)
local function colorTemp(t)
    t.Writable = 'undef'
    t.Count = 4
    t.ValueConv = function(_self, val)
        val = str(val)
        if #val ~= 4 then return val end
        local a = { unpack_('nCC', val) }
        a[1] = 53190 - a[1]
        local lo = a[3] & 0x0f; if lo >= 8 then lo = lo - 16 end
        local hi = a[3] >> 4;   if hi >= 8 then hi = hi - 16 end
        a[2], a[3] = lo, hi
        return a[1] .. ' ' .. a[2] .. ' ' .. a[3]
    end
    t.ValueConvInv = function(_self, val)
        local a = {}
        for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = tonumber(w) end
        if #a ~= 3 then return nil end
        return pack_('nCC', 53190 - a[1], 0, (a[2] & 0x0f) + ((a[3] & 0x0f) << 4))
    end
    t.PrintConv = function(_self, val)
        val = str(val)
        val = val:gsub(' ([1-9])', ' +%1')
        val = val:gsub(' 0', '  0')
        return val
    end
    t.PrintConvInv = function(_self, val) return val end
    return t
end

-- conversions for KelvinWB tags
-- (upstream is the hash %kelvinWB, spread into a tag entry; conventions.md §2
--  turns a spread hash into a helper that fills in the shared entries)
local function kelvinWB(t)
    t.Format = 'int16u[4]'
    t.ValueConv = function(_self, val)
        local a = {}
        for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = tonumber(w) end
        return (53190 - a[1]) .. ' ' .. a[2] .. ' ' .. (a[3] / 8192) .. ' ' .. (a[4] / 8192)
    end
    t.ValueConvInv = function(_self, val)
        local a = {}
        for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = tonumber(w) end
        return (53190 - a[1]) .. ' ' .. a[2] .. ' ' ..
               math.floor(a[3] * 8192 + 0.5) .. ' ' .. math.floor(a[4] * 8192 + 0.5)
    end
    return t
end

local noYes = { [0] = 'No', [1] = 'Yes' }

-- convert 16 or 77 metering segment values to approximate LV equivalent - PH
local convertMeteringSegments = {
    PrintConv = function(_self, val)
        local out = {}
        for w in str(val):gmatch('[^ \t\n\r\f\v]+') do
            local n = tonumber(w)
            if n == 255 then
                out[#out + 1] = 'n/a'
            elseif n == 0 then
                out[#out + 1] = '0'
            else
                out[#out + 1] = sprintf('%.1f', n / 8 - 6)
            end
        end
        return table.concat(out, ' ')
    end,
    PrintConvInv = function(_self, val)
        local out = {}
        for _, v in ipairs(perl.split(' ', val)) do
            if perl.isMatch(v, '(?i)^n') then
                out[#out + 1] = 255
            elseif perl.num(v) == 0 then
                out[#out + 1] = '0'
            else
                out[#out + 1] = perl.int((perl.num(v) + 6) * 8 + 0.5)
            end
        end
        return perl.join(' ', out)
    end,
}

-- pentax lens type codes (ref 4)
-- The first number gives the lens series, and the 2nd gives the model number
-- Series numbers: K=1; A=2; F=3; FAJ=4; DFA=4,7; FA=3,4,5,6; FA*=5,6;
--                 DA=3,4,7; DA*=7,8; FA645=11; DFA645=13; Q=21
local pentaxLensTypes = {
    Notes = [[
        The first number gives the series of the lens, and the second identifies the
        lens model.  Note that newer series numbers may not always be properly
        identified by cameras running older firmware versions.
    ]],
    OTHER = function(val, inv, conv)
        local orig = val
        if inv then return nil end
        -- *istD may report a series number of 4 for series 7 lenses
        if matches(val, [[^4 ]]) then
            val = subst(val, [[^4 ]], '7 ')
            if conv[val] then return conv[val] .. ' (' .. orig .. ')' end
        end
        -- cameras that don't recognize SDM lenses (eg. older K10 firmware)
        -- may report series 7 instead of 8
        if matches(val, [[^7 ]]) then
            val = subst(val, [[^7 ]], '8 ')
            if conv[val] then return conv[val] .. ' ? (' .. orig .. ')' end
        end
        -- there seems to some inconsistency between FA and DFA lenses for the 645D...
        if matches(val, [[^11 ]]) then
            val = subst(val, [[^11 ]], '13 ')
            if conv[val] then return conv[val] .. ' ? (' .. orig .. ')' end
        elseif matches(val, [[^13 ]]) then
            val = subst(val, [[^13 ]], '11 ')
            if conv[val] then return conv[val] .. ' ? (' .. orig .. ')' end
        end
        return nil
    end,
    ['0 0'] = 'M-42 or No Lens', -- #17
    ['1 0'] = 'K or M Lens',
    ['2 0'] = 'A Series Lens', -- #7 (from smc PENTAX-A 400mm F5.6)
    ['3 0'] = 'Sigma',
    -- (and 'Sigma 18-50mm F2.8 EX Macro')
    -- (and 'Sigma 30mm F1.4 EX DC', ref PH)
    -- (and 'Sigma 50-500mm F4-6.3 DG APO')
    -- (and 'Sigma 70mm F2.8 EX DG Macro')
    -- (and 'Sigma 105mm F2.8 EX DG Macro', ref 24)
    -- (and 'Sigma 180mm F4.5 EX DG Macro')
    ['3 17'] = 'smc PENTAX-FA SOFT 85mm F2.8', -- (also F version, ref 29)
    ['3 18'] = 'smc PENTAX-F 1.7X AF ADAPTER',
    ['3 19'] = 'smc PENTAX-F 24-50mm F4',
    ['3 20'] = 'smc PENTAX-F 35-80mm F4-5.6',
    ['3 21'] = 'smc PENTAX-F 80-200mm F4.7-5.6',
    ['3 22'] = 'smc PENTAX-F FISH-EYE 17-28mm F3.5-4.5',
    ['3 23'] = 'smc PENTAX-F 100-300mm F4.5-5.6 or Sigma Lens',
    ['3 23.1'] = 'Sigma AF 28-300mm F3.5-5.6 DL IF', -- #JD
    ['3 23.2'] = 'Sigma AF 28-300mm F3.5-6.3 DG IF Macro', -- #JD
    ['3 23.3'] = 'Tokina 80-200mm F2.8 ATX-Pro', -- #Exiv2
    ['3 24'] = 'smc PENTAX-F 35-135mm F3.5-4.5',
    ['3 25'] = 'smc PENTAX-F 35-105mm F4-5.6 or Sigma or Tokina Lens',
    ['3 25.1'] = 'Sigma 55-200mm F4-5.6 DC', -- #JD
    ['3 25.2'] = 'Sigma AF 28-300mm F3.5-5.6 DL IF', -- #11
    ['3 25.3'] = 'Sigma AF 28-300mm F3.5-6.3 DL IF', -- #Exiv2
    ['3 25.4'] = 'Sigma AF 28-300mm F3.5-6.3 DG IF Macro', -- #JD
    ['3 25.5'] = 'Tokina 80-200mm F2.8 ATX-Pro', -- #12
    ['3 26'] = 'smc PENTAX-F* 250-600mm F5.6 ED[IF]',
    ['3 27'] = 'smc PENTAX-F 28-80mm F3.5-4.5 or Tokina Lens',
    ['3 27.1'] = 'Tokina AT-X Pro AF 28-70mm F2.6-2.8', -- #JD
    ['3 28'] = 'smc PENTAX-F 35-70mm F3.5-4.5 or Tokina Lens',
    ['3 28.1'] = 'Tokina 19-35mm F3.5-4.5 AF', -- #12
    ['3 28.2'] = 'Tokina AT-X AF 400mm F5.6', -- #NJ
    ['3 29'] = 'PENTAX-F 28-80mm F3.5-4.5 or Sigma or Tokina Lens',
    ['3 29.1'] = 'Sigma AF 18-125mm F3.5-5.6 DC', -- #11
    ['3 29.2'] = 'Tokina AT-X PRO 28-70mm F2.6-2.8', -- #22
    ['3 30'] = 'PENTAX-F 70-200mm F4-5.6',
    ['3 31'] = 'smc PENTAX-F 70-210mm F4-5.6 or Tokina or Takumar Lens',
    ['3 31.1'] = 'Tokina AF 730 75-300mm F4.5-5.6',
    ['3 31.2'] = 'Takumar-F 70-210mm F4-5.6', -- #JD
    ['3 32'] = 'smc PENTAX-F 50mm F1.4',
    ['3 33'] = 'smc PENTAX-F 50mm F1.7',
    ['3 34'] = 'smc PENTAX-F 135mm F2.8 [IF]',
    ['3 35'] = 'smc PENTAX-F 28mm F2.8',
    ['3 36'] = 'Sigma 20mm F1.8 EX DG Aspherical RF',
    ['3 38'] = 'smc PENTAX-F* 300mm F4.5 ED[IF]',
    ['3 39'] = 'smc PENTAX-F* 600mm F4 ED[IF]',
    ['3 40'] = 'smc PENTAX-F Macro 100mm F2.8',
    ['3 41'] = 'smc PENTAX-F Macro 50mm F2.8 or Sigma Lens', -- #4
    ['3 41.1'] = 'Sigma 50mm F2.8 Macro', -- #16
    ['3 42'] = 'Sigma 300mm F2.8 EX DG APO IF', -- #27
    ['3 44'] = 'Sigma or Tamron Lens (3 44)',
    ['3 44.1'] = 'Sigma AF 10-20mm F4-5.6 EX DC', -- #JD
    ['3 44.2'] = 'Sigma 12-24mm F4.5-5.6 EX DG', -- #12 (added "-5.6", ref 29)
    ['3 44.3'] = 'Sigma 17-70mm F2.8-4.5 DC Macro', -- #(Bart Hickman)
    ['3 44.4'] = 'Sigma 18-50mm F3.5-5.6 DC', -- #4
    ['3 44.5'] = 'Sigma 17-35mm F2.8-4 EX DG', -- #29
    ['3 44.6'] = 'Tamron 35-90mm F4-5.6 AF', -- #12 (added "-5.6", ref IB)
    ['3 44.7'] = 'Sigma AF 18-35mm F3.5-4.5 Aspherical', -- #29
    ['3 46'] = 'Sigma or Samsung Lens (3 46)',
    ['3 46.1'] = 'Sigma APO 70-200mm F2.8 EX',
    ['3 46.2'] = 'Sigma EX APO 100-300mm F4 IF', -- #JD
    ['3 46.3'] = 'Samsung/Schneider D-XENON 50-200mm F4-5.6 ED', -- #29
    ['3 50'] = 'smc PENTAX-FA 28-70mm F4 AL',
    ['3 51'] = 'Sigma 28mm F1.8 EX DG Aspherical Macro',
    ['3 52'] = 'smc PENTAX-FA 28-200mm F3.8-5.6 AL[IF] or Tamron Lens',
    ['3 52.1'] = 'Tamron AF LD 28-200mm F3.8-5.6 [IF] Aspherical (171D)', -- #JD
    ['3 53'] = 'smc PENTAX-FA 28-80mm F3.5-5.6 AL',
    ['3 247'] = 'smc PENTAX-DA FISH-EYE 10-17mm F3.5-4.5 ED[IF]',
    ['3 248'] = 'smc PENTAX-DA 12-24mm F4 ED AL[IF]',
    ['3 250'] = 'smc PENTAX-DA 50-200mm F4-5.6 ED',
    ['3 251'] = 'smc PENTAX-DA 40mm F2.8 Limited',
    ['3 252'] = 'smc PENTAX-DA 18-55mm F3.5-5.6 AL',
    ['3 253'] = 'smc PENTAX-DA 14mm F2.8 ED[IF]',
    ['3 254'] = 'smc PENTAX-DA 16-45mm F4 ED AL',
    ['3 255'] = 'Sigma Lens (3 255)',
    ['3 255.1'] = 'Sigma 18-200mm F3.5-6.3 DC', -- #8
    ['3 255.2'] = 'Sigma DL-II 35-80mm F4-5.6', -- #12
    ['3 255.3'] = 'Sigma DL Zoom 75-300mm F4-5.6', -- #12
    ['3 255.4'] = 'Sigma DF EX Aspherical 28-70mm F2.8', -- #12
    ['3 255.5'] = 'Sigma AF Tele 400mm F5.6 Multi-coated', -- #JD
    ['3 255.6'] = 'Sigma 24-60mm F2.8 EX DG', -- #PH
    ['3 255.7'] = 'Sigma 70-300mm F4-5.6 Macro', -- #JD (also DG Macro, ref 27)
    ['3 255.8'] = 'Sigma 55-200mm F4-5.6 DC', -- #JD
    ['3 255.9'] = 'Sigma 18-50mm F2.8 EX DC', -- #JD (also Macro version - PH)
    ['4 1'] = 'smc PENTAX-FA SOFT 28mm F2.8',
    ['4 2'] = 'smc PENTAX-FA 80-320mm F4.5-5.6',
    ['4 3'] = 'smc PENTAX-FA 43mm F1.9 Limited',
    ['4 6'] = 'smc PENTAX-FA 35-80mm F4-5.6',
    ['4 7'] = 'Irix 45mm F1.4', -- #27
    ['4 8'] = 'Irix 150mm F2.8 Macro', -- #exiv2 issue 1084
    ['4 9'] = 'Irix 11mm F4 Firefly', -- #27 (guessing the Blackstone version may be the same ID - PH)
    ['4 10'] = 'Irix 15mm F2.4', -- #27
    ['4 12'] = 'smc PENTAX-FA 50mm F1.4', -- #17
    ['4 15'] = 'smc PENTAX-FA 28-105mm F4-5.6 [IF]',
    ['4 16'] = 'Tamron AF 80-210mm F4-5.6 (178D)', -- #13
    ['4 19'] = 'Tamron SP AF 90mm F2.8 (172E)',
    ['4 20'] = 'smc PENTAX-FA 28-80mm F3.5-5.6',
    ['4 21'] = 'Cosina AF 100-300mm F5.6-6.7', -- #20
    ['4 22'] = 'Tokina 28-80mm F3.5-5.6', -- #13
    ['4 23'] = 'smc PENTAX-FA 20-35mm F4 AL',
    ['4 24'] = 'smc PENTAX-FA 77mm F1.8 Limited',
    ['4 25'] = 'Tamron SP AF 14mm F2.8', -- #13
    ['4 26'] = 'smc PENTAX-FA Macro 100mm F3.5 or Cosina Lens',
    ['4 26.1'] = 'Cosina 100mm F3.5 Macro', -- #JD
    ['4 27'] = 'Tamron AF 28-300mm F3.5-6.3 LD Aspherical[IF] Macro (185D/285D)',
    ['4 28'] = 'smc PENTAX-FA 35mm F2 AL',
    ['4 29'] = 'Tamron AF 28-200mm F3.8-5.6 LD Super II Macro (371D)', -- #JD
    ['4 34'] = 'smc PENTAX-FA 24-90mm F3.5-4.5 AL[IF]',
    ['4 35'] = 'smc PENTAX-FA 100-300mm F4.7-5.8',
  -- '4 36' => 'Tamron AF70-300mm F4-5.6 LD Macro', # both 572D and A17 (Di) - ref JD
    ['4 36'] = 'Tamron AF 70-300mm F4-5.6 LD Macro 1:2', -- #NJ
    ['4 37'] = 'Tamron SP AF 24-135mm F3.5-5.6 AD AL (190D)', -- #13
    ['4 38'] = 'smc PENTAX-FA 28-105mm F3.2-4.5 AL[IF]',
    ['4 39'] = 'smc PENTAX-FA 31mm F1.8 AL Limited',
    ['4 41'] = 'Tamron AF 28-200mm Super Zoom F3.8-5.6 Aspherical XR [IF] Macro (A03)',
    ['4 43'] = 'smc PENTAX-FA 28-90mm F3.5-5.6',
    ['4 44'] = 'smc PENTAX-FA J 75-300mm F4.5-5.8 AL',
    ['4 45'] = 'Tamron Lens (4 45)',
    ['4 45.1'] = 'Tamron 28-300mm F3.5-6.3 Ultra zoom XR',
    ['4 45.2'] = 'Tamron AF 28-300mm F3.5-6.3 XR Di LD Aspherical [IF] Macro', -- #JD
    ['4 46'] = 'smc PENTAX-FA J 28-80mm F3.5-5.6 AL',
    ['4 47'] = 'smc PENTAX-FA J 18-35mm F4-5.6 AL',
   -- #'4 49' => 'Tamron SP AF 28-75mm F2.8 XR Di (A09)',
    ['4 49'] = 'Tamron SP AF 28-75mm F2.8 XR Di LD Aspherical [IF] Macro', -- #NJ
    ['4 51'] = 'smc PENTAX-D FA 50mm F2.8 Macro',
    ['4 52'] = 'smc PENTAX-D FA 100mm F2.8 Macro',
    ['4 55'] = 'Samsung/Schneider D-XENOGON 35mm F2', -- #29
    ['4 56'] = 'Samsung/Schneider D-XENON 100mm F2.8 Macro', -- #Alan Robinson
    ['4 75'] = 'Tamron SP AF 70-200mm F2.8 Di LD [IF] Macro (A001)', -- #JD
    ['4 214'] = 'smc PENTAX-DA 35mm F2.4 AL', -- #PH
    ['4 229'] = 'smc PENTAX-DA 18-55mm F3.5-5.6 AL II', -- #JD
    ['4 230'] = 'Tamron SP AF 17-50mm F2.8 XR Di II', -- #20
    ['4 231'] = 'smc PENTAX-DA 18-250mm F3.5-6.3 ED AL [IF]', -- #21
    ['4 237'] = 'Samsung/Schneider D-XENOGON 10-17mm F3.5-4.5', -- #JD
    ['4 239'] = 'Samsung/Schneider D-XENON 12-24mm F4 ED AL [IF]', -- #23
    ['4 242'] = 'smc PENTAX-DA* 16-50mm F2.8 ED AL [IF] SDM (SDM unused)', -- #Pietu Pohjalainen
    ['4 243'] = 'smc PENTAX-DA 70mm F2.4 Limited', -- #JD
    ['4 244'] = 'smc PENTAX-DA 21mm F3.2 AL Limited', -- #9
    ['4 245'] = 'Samsung/Schneider D-XENON 50-200mm F4-5.6', -- #15
    ['4 246'] = 'Samsung/Schneider D-XENON 18-55mm F3.5-5.6', -- #15
    ['4 247'] = 'smc PENTAX-DA FISH-EYE 10-17mm F3.5-4.5 ED[IF]', -- #10
    ['4 248'] = 'smc PENTAX-DA 12-24mm F4 ED AL [IF]', -- #10
    ['4 249'] = 'Tamron XR DiII 18-200mm F3.5-6.3 (A14)',
    ['4 250'] = 'smc PENTAX-DA 50-200mm F4-5.6 ED', -- #8
    ['4 251'] = 'smc PENTAX-DA 40mm F2.8 Limited', -- #9
    ['4 252'] = 'smc PENTAX-DA 18-55mm F3.5-5.6 AL', -- #8
    ['4 253'] = 'smc PENTAX-DA 14mm F2.8 ED[IF]',
    ['4 254'] = 'smc PENTAX-DA 16-45mm F4 ED AL',
    ['5 1'] = 'smc PENTAX-FA* 24mm F2 AL[IF]',
    ['5 2'] = 'smc PENTAX-FA 28mm F2.8 AL',
    ['5 3'] = 'smc PENTAX-FA 50mm F1.7',
    ['5 4'] = 'smc PENTAX-FA 50mm F1.4',
    ['5 5'] = 'smc PENTAX-FA* 600mm F4 ED[IF]',
    ['5 6'] = 'smc PENTAX-FA* 300mm F4.5 ED[IF]',
    ['5 7'] = 'smc PENTAX-FA 135mm F2.8 [IF]',
    ['5 8'] = 'smc PENTAX-FA Macro 50mm F2.8',
    ['5 9'] = 'smc PENTAX-FA Macro 100mm F2.8',
    ['5 10'] = 'smc PENTAX-FA* 85mm F1.4 [IF]',
    ['5 11'] = 'smc PENTAX-FA* 200mm F2.8 ED[IF]',
    ['5 12'] = 'smc PENTAX-FA 28-80mm F3.5-4.7',
    ['5 13'] = 'smc PENTAX-FA 70-200mm F4-5.6',
    ['5 14'] = 'smc PENTAX-FA* 250-600mm F5.6 ED[IF]',
    ['5 15'] = 'smc PENTAX-FA 28-105mm F4-5.6',
    ['5 16'] = 'smc PENTAX-FA 100-300mm F4.5-5.6',
    ['5 98'] = 'smc PENTAX-FA 100-300mm F4.5-5.6', -- #JD (pre-production? - PH)
    ['6 1'] = 'smc PENTAX-FA* 85mm F1.4 [IF]',
    ['6 2'] = 'smc PENTAX-FA* 200mm F2.8 ED[IF]',
    ['6 3'] = 'smc PENTAX-FA* 300mm F2.8 ED[IF]',
    ['6 4'] = 'smc PENTAX-FA* 28-70mm F2.8 AL',
    ['6 5'] = 'smc PENTAX-FA* 80-200mm F2.8 ED[IF]',
    ['6 6'] = 'smc PENTAX-FA* 28-70mm F2.8 AL',
    ['6 7'] = 'smc PENTAX-FA* 80-200mm F2.8 ED[IF]',
    ['6 8'] = 'smc PENTAX-FA 28-70mm F4AL',
    ['6 9'] = 'smc PENTAX-FA 20mm F2.8',
    ['6 10'] = 'smc PENTAX-FA* 400mm F5.6 ED[IF]',
    ['6 13'] = 'smc PENTAX-FA* 400mm F5.6 ED[IF]',
    ['6 14'] = 'smc PENTAX-FA* Macro 200mm F4 ED[IF]',
    ['7 0'] = 'smc PENTAX-DA 21mm F3.2 AL Limited', -- #13
    ['7 58'] = 'smc PENTAX-D FA Macro 100mm F2.8 WR', -- #PH - this bit of information cost me $600 ;)
  -- '7 58' also 'HD PENTAX-D FA MACRO 100mm F2.8 ED AW' (ref 27)
    ['7 75'] = 'Tamron SP AF 70-200mm F2.8 Di LD [IF] Macro (A001)', -- #(Anton Bondar)
    ['7 201'] = 'smc Pentax-DA L 50-200mm F4-5.6 ED WR', -- #(Bruce Rusk)
    ['7 202'] = 'smc PENTAX-DA L 18-55mm F3.5-5.6 AL WR', -- #29
    ['7 203'] = 'HD PENTAX-DA 55-300mm F4-5.8 ED WR', -- #29
    ['7 204'] = 'HD PENTAX-DA 15mm F4 ED AL Limited', -- #forum5318
    ['7 205'] = 'HD PENTAX-DA 35mm F2.8 Macro Limited', -- #29
    ['7 206'] = 'HD PENTAX-DA 70mm F2.4 Limited', -- #29
    ['7 207'] = 'HD PENTAX-DA 21mm F3.2 ED AL Limited', -- #forum5327
    ['7 208'] = 'HD PENTAX-DA 40mm F2.8 Limited', -- #PH
    ['7 212'] = 'smc PENTAX-DA 50mm F1.8', -- #PH
    ['7 213'] = 'smc PENTAX-DA 40mm F2.8 XS', -- #PH
    ['7 214'] = 'smc PENTAX-DA 35mm F2.4 AL', -- #PH
    ['7 216'] = 'smc PENTAX-DA L 55-300mm F4-5.8 ED', -- #PH
    ['7 217'] = 'smc PENTAX-DA 50-200mm F4-5.6 ED WR', -- #JD
    ['7 218'] = 'smc PENTAX-DA 18-55mm F3.5-5.6 AL WR', -- #JD
    ['7 220'] = 'Tamron SP AF 10-24mm F3.5-4.5 Di II LD Aspherical [IF]', -- #24
    ['7 221'] = 'smc PENTAX-DA L 50-200mm F4-5.6 ED', -- #Ar't
    ['7 222'] = 'smc PENTAX-DA L 18-55mm F3.5-5.6', -- #PH (tag 0x003f -- was '7 229' in LensInfo of one test image)
    ['7 223'] = 'Samsung/Schneider D-XENON 18-55mm F3.5-5.6 II', -- #PH
    ['7 224'] = 'smc PENTAX-DA 15mm F4 ED AL Limited', -- #JD
    ['7 225'] = 'Samsung/Schneider D-XENON 18-250mm F3.5-6.3', -- #8/PH
    ['7 226'] = 'smc PENTAX-DA* 55mm F1.4 SDM (SDM unused)', -- #PH (NC)
    ['7 227'] = 'smc PENTAX-DA* 60-250mm F4 [IF] SDM (SDM unused)', -- #PH (NC)
    ['7 228'] = 'Samsung 16-45mm F4 ED', -- #29
    ['7 229'] = 'smc PENTAX-DA 18-55mm F3.5-5.6 AL II', -- #JD
    ['7 230'] = 'Tamron AF 17-50mm F2.8 XR Di-II LD (Model A16)', -- #JD
    ['7 231'] = 'smc PENTAX-DA 18-250mm F3.5-6.3 ED AL [IF]', -- #JD
    ['7 233'] = 'smc PENTAX-DA 35mm F2.8 Macro Limited', -- #JD
    ['7 234'] = 'smc PENTAX-DA* 300mm F4 ED [IF] SDM (SDM unused)', -- #19 (NC)
    ['7 235'] = 'smc PENTAX-DA* 200mm F2.8 ED [IF] SDM (SDM unused)', -- #PH (NC)
    ['7 236'] = 'smc PENTAX-DA 55-300mm F4-5.8 ED', -- #JD
    ['7 238'] = 'Tamron AF 18-250mm F3.5-6.3 Di II LD Aspherical [IF] Macro', -- #JD
    ['7 241'] = 'smc PENTAX-DA* 50-135mm F2.8 ED [IF] SDM (SDM unused)', -- #PH
    ['7 242'] = 'smc PENTAX-DA* 16-50mm F2.8 ED AL [IF] SDM (SDM unused)', -- #19
    ['7 243'] = 'smc PENTAX-DA 70mm F2.4 Limited', -- #PH
    ['7 244'] = 'smc PENTAX-DA 21mm F3.2 AL Limited', -- #16
    ['8 0'] = 'Sigma 50-150mm F2.8 II APO EX DC HSM', -- #forum2997
    ['8 3'] = 'Sigma 18-125mm F3.8-5.6 DC HSM', -- #forum10167
    ['8 4'] = 'Sigma 50mm F1.4 EX DG HSM', -- #Artur private communication
    ['8 6'] = 'Sigma 4.5mm F2.8 EX DC Fisheye', -- #IB
    ['8 7'] = 'Sigma 24-70mm F2.8 IF EX DG HSM', -- #Exiv2
    ['8 8'] = 'Sigma 18-250mm F3.5-6.3 DC OS HSM', -- #27
    ['8 11'] = 'Sigma 10-20mm F3.5 EX DC HSM', -- #27
    ['8 12'] = 'Sigma 70-300mm F4-5.6 DG OS', -- #forum3382
    ['8 13'] = 'Sigma 120-400mm F4.5-5.6 APO DG OS HSM', -- #26
    ['8 14'] = 'Sigma 17-70mm F2.8-4.0 DC Macro OS HSM', -- #(Hubert Meier)
    ['8 15'] = 'Sigma 150-500mm F5-6.3 APO DG OS HSM', -- #26
    ['8 16'] = 'Sigma 70-200mm F2.8 EX DG Macro HSM II', -- #26
    ['8 17'] = 'Sigma 50-500mm F4.5-6.3 DG OS HSM', -- #(Heike Herrmann) (also APO, ref 26)
    ['8 18'] = 'Sigma 8-16mm F4.5-5.6 DC HSM', -- #forum2998
    ['8 20'] = 'Sigma 18-50mm F2.8-4.5 DC HSM', -- #IB
    ['8 21'] = 'Sigma 17-50mm F2.8 EX DC OS HSM', -- #26
    ['8 22'] = 'Sigma 85mm F1.4 EX DG HSM', -- #26
    ['8 23'] = 'Sigma 70-200mm F2.8 APO EX DG OS HSM', -- #27
    ['8 24'] = 'Sigma 17-70mm F2.8-4 DC Macro OS HSM', -- #27
    ['8 25'] = 'Sigma 17-50mm F2.8 EX DC HSM', -- #Exiv2
    ['8 27'] = 'Sigma 18-200mm F3.5-6.3 II DC HSM', -- #27
    ['8 28'] = 'Sigma 18-250mm F3.5-6.3 DC Macro HSM', -- #27
    ['8 29'] = 'Sigma 35mm F1.4 DG HSM', -- #27
    ['8 30'] = 'Sigma 17-70mm F2.8-4 DC Macro HSM | C', -- #27
    ['8 31'] = 'Sigma 18-35mm F1.8 DC HSM', -- #27
    ['8 32'] = 'Sigma 30mm F1.4 DC HSM | A', -- #27
    ['8 33'] = 'Sigma 18-200mm F3.5-6.3 DC Macro HSM', -- #DieterPearcey (C014)
    ['8 34'] = 'Sigma 18-300mm F3.5-6.3 DC Macro HSM', -- #NJ
    ['8 59'] = 'HD PENTAX-D FA 150-450mm F4.5-5.6 ED DC AW', -- #29
    ['8 60'] = 'HD PENTAX-D FA* 70-200mm F2.8 ED DC AW', -- #29
    ['8 61'] = 'HD PENTAX-D FA 28-105mm F3.5-5.6 ED DC WR', -- #PH
    ['8 62'] = 'HD PENTAX-D FA 24-70mm F2.8 ED SDM WR', -- #PH
    ['8 63'] = 'HD PENTAX-D FA 15-30mm F2.8 ED SDM WR', -- #PH
    ['8 64'] = 'HD PENTAX-D FA* 50mm F1.4 SDM AW', -- #27
    ['8 65'] = 'HD PENTAX-D FA 70-210mm F4 ED SDM WR', -- #PH
    ['8 66'] = 'HD PENTAX-D FA 85mm F1.4 ED SDM AW', -- #James O'Neill
    ['8 67'] = 'HD PENTAX-D FA 21mm F2.4 ED Limited DC WR', -- #ChristianShulz
    ['8 195'] = 'HD PENTAX DA* 16-50mm F2.8 ED PLM AW', -- #27
    ['8 196'] = 'HD PENTAX-DA* 11-18mm F2.8 ED DC AW', -- #29
    ['8 197'] = 'HD PENTAX-DA 55-300mm F4.5-6.3 ED PLM WR RE', -- #29
    ['8 198'] = 'smc PENTAX-DA L 18-50mm F4-5.6 DC WR RE', -- #29
    ['8 199'] = 'HD PENTAX-DA 18-50mm F4-5.6 DC WR RE', -- #29
    ['8 200'] = 'HD PENTAX-DA 16-85mm F3.5-5.6 ED DC WR', -- #29
    ['8 209'] = 'HD PENTAX-DA 20-40mm F2.8-4 ED Limited DC WR', -- #29
    ['8 210'] = 'smc PENTAX-DA 18-270mm F3.5-6.3 ED SDM', -- #Helmut Schutz
    ['8 211'] = 'HD PENTAX-DA 560mm F5.6 ED AW', -- #PH
    ['8 215'] = 'smc PENTAX-DA 18-135mm F3.5-5.6 ED AL [IF] DC WR', -- #PH
    ['8 226'] = 'smc PENTAX-DA* 55mm F1.4 SDM', -- #JD
    ['8 227'] = 'smc PENTAX-DA* 60-250mm F4 [IF] SDM', -- #JD
    ['8 232'] = 'smc PENTAX-DA 17-70mm F4 AL [IF] SDM', -- #JD
    ['8 234'] = 'smc PENTAX-DA* 300mm F4 ED [IF] SDM', -- #19
    ['8 235'] = 'smc PENTAX-DA* 200mm F2.8 ED [IF] SDM', -- #JD
    ['8 241'] = 'smc PENTAX-DA* 50-135mm F2.8 ED [IF] SDM', -- #JD
    ['8 242'] = 'smc PENTAX-DA* 16-50mm F2.8 ED AL [IF] SDM', -- #JD
    ['8 255'] = 'Sigma Lens (8 255)',
    ['8 255.1'] = 'Sigma 70-200mm F2.8 EX DG Macro HSM II', -- #JD
    ['8 255.2'] = 'Sigma 150-500mm F5-6.3 DG APO [OS] HSM', -- #JD (non-OS version has same type, ref 29)
    ['8 255.3'] = 'Sigma 50-150mm F2.8 II APO EX DC HSM', -- #forum2997
    ['8 255.4'] = 'Sigma 4.5mm F2.8 EX DC HSM Circular Fisheye', -- #PH
    ['8 255.5'] = 'Sigma 50-200mm F4-5.6 DC OS', -- #26
    ['8 255.6'] = 'Sigma 24-70mm F2.8 EX DG HSM', -- #29

    ['9 0'] = '645 Manual Lens', -- #PH (NC)
    ['9 3'] = 'HD PENTAX-FA 43mm F1.9 Limited', -- #IB
    ['9 24'] = 'HD PENTAX-FA 77mm F1.8 Limited', -- #IB
    ['9 39'] = 'HD PENTAX-FA 31mm F1.8 AL Limited', -- #IB
    ['9 247'] = 'HD PENTAX-DA FISH-EYE 10-17mm F3.5-4.5 ED [IF]', -- #IB
--
-- 645 lenses
--
    ['10 0'] = '645 A Series Lens', -- #PH
    ['11 1'] = 'smc PENTAX-FA 645 75mm F2.8', -- #PH
    ['11 2'] = 'smc PENTAX-FA 645 45mm F2.8', -- #PH
    ['11 3'] = 'smc PENTAX-FA* 645 300mm F4 ED [IF]', -- #PH
    ['11 4'] = 'smc PENTAX-FA 645 45-85mm F4.5', -- #PH
    ['11 5'] = 'smc PENTAX-FA 645 400mm F5.6 ED [IF]', -- #PH
    ['11 7'] = 'smc PENTAX-FA 645 Macro 120mm F4', -- #PH
    ['11 8'] = 'smc PENTAX-FA 645 80-160mm F4.5', -- #PH
    ['11 9'] = 'smc PENTAX-FA 645 200mm F4 [IF]', -- #PH
    ['11 10'] = 'smc PENTAX-FA 645 150mm F2.8 [IF]', -- #PH
    ['11 11'] = 'smc PENTAX-FA 645 35mm F3.5 AL [IF]', -- #PH
    ['11 12'] = 'smc PENTAX-FA 645 300mm F5.6 ED [IF]', -- #29
    ['11 14'] = 'smc PENTAX-FA 645 55-110mm F5.6', -- #PH
    ['11 16'] = 'smc PENTAX-FA 645 33-55mm F4.5 AL', -- #PH
    ['11 17'] = 'smc PENTAX-FA 645 150-300mm F5.6 ED [IF]', -- #PH
    ['11 21'] = 'HD PENTAX-D FA 645 35mm F3.5 AL [IF]', -- #29
    ['13 18'] = 'smc PENTAX-D FA 645 55mm F2.8 AL [IF] SDM AW', -- #PH
    ['13 19'] = 'smc PENTAX-D FA 645 25mm F4 AL [IF] SDM AW', -- #PH
    ['13 20'] = 'HD PENTAX-D FA 645 90mm F2.8 ED AW SR', -- #PH
    ['13 253'] = 'HD PENTAX-DA 645 28-45mm F4.5 ED AW SR', -- #Dominique Schrekling email
    ['13 254'] = 'smc PENTAX-DA 645 25mm F4 AL [IF] SDM AW', -- #forum8253
--
-- Q-mount lenses (21=auto focus lens, 22=manual focus)
--
    ['20 0'] = 'Pentax Q Manual Lens (Q, Q10)', -- #27
    ['21 0'] = 'Pentax Q Manual Lens', -- #PH (Q7, Q-S1)
    ['21 1'] = '01 Standard Prime 8.5mm F1.9', -- #PH
    ['21 2'] = '02 Standard Zoom 5-15mm F2.8-4.5', -- #PH
    ['22 3'] = '03 Fish-eye 3.2mm F5.6', -- #PH
    ['22 4'] = '04 Toy Lens Wide 6.3mm F7.1', -- #PH
    ['22 5'] = '05 Toy Lens Telephoto 18mm F8', -- #PH
    ['21 6'] = '06 Telephoto Zoom 15-45mm F2.8', -- #PH
    ['21 7'] = '07 Mount Shield 11.5mm F9', -- #PH (NC)
    ['21 8'] = '08 Wide Zoom 3.8-5.9mm F3.7-4', -- #PH (NC)
    ['21 233'] = 'Adapter Q for K-mount Lens', -- #29
--
-- Ricoh lenses
--
    ['31 1'] = '18.3mm F2.8', -- #PH (GR III built-in)
    ['31 4'] = '26.1mm F2.8', -- #PH (GR IIIx built-in)
    ['31 5'] = '26.1mm F2.8 GT-2 TC', -- #KG (GR IIIx built-in plus GT-2 TC)
    ['31 8'] = '18.3mm F2.8', -- #KG (GR IV built-in)
}
-- (upstream package variable %pentaxLensTypes, read by XMP::PrintLensID)
Pentax.pentaxLensTypes = pentaxLensTypes

-- Convert number to approximate EV (modulo 8) (upstream PentaxEv)
local function PentaxEv(val)
    if (val & 0x01) ~= 0 then
        local sign = val < 0 and -1 or 1
        local frac = (val * sign) & 0x07
        if frac == 0x03 then
            val = val + sign * (8 / 3 - frac)
        elseif frac == 0x05 then
            val = val + sign * (16 / 3 - frac)
        end
    end
    return val / 8
end

-- Convert approximate EV (modulo 8) to number (upstream PentaxEvInv)
local function PentaxEvInv(num)
    local val = num * 8
    -- extra fudging makes sure 0.3 and 0.33333 both round up to 3, etc
    local sign = num < 0 and -1 or 1
    local inum = num * sign - math.floor(num * sign)
    if inum > 0.29 and inum < 0.4 then
        val = val + sign / 3
    elseif inum > 0.6 and inum < .71 then
        val = val - sign / 3
    end
    local r = val + 0.5 * sign
    return r < 0 and math.ceil(r) or math.floor(r)
end

-- Encrypt or decrypt Pentax ShutterCount (symmetrical encryption) - PH
-- Inputs: 0) shutter count value, 1) ExifTool object ref
-- Returns: Encrypted or decrypted ShutterCount
local function CryptShutterCount(val, et)
    -- Pentax Date and Time values are used in the encryption
    if not (et.PentaxDate and et.PentaxTime and #et.PentaxDate == 4 and #et.PentaxTime >= 3) then
        return nil
    end
    local d1, d2, d3, d4 = et.PentaxDate:byte(1, 4)
    local date = ((d1 * 256 + d2) * 256 + d3) * 256 + d4
    local t1, t2, t3 = et.PentaxTime:byte(1, 3)
    local time = ((((t1 * 256 + t2) * 256 + t3) * 256) + 0)
    return val ~ date ~ (0xffffffff - time)
end

--------------------------------------------------------------------------------
-- PrintConv for digital filter settings (ref PH)
-- Inputs: 0) value to convert, 1) flag for inverse conversion, 2) lookup table
-- Returns: converted value (a list of filter settings)
-- Port notes: the reverse (write) conversion is not ported -- read-only subset.
function PrintFilter(val, _inv, conv)
    local vals, cval = {}, {}
    for w in str(val):gmatch('[^ \t\n\r\f\v]+') do vals[#vals + 1] = tonumber(w) end
    -- forward conversion (reading):
    local i = 1
    local t = vals[i]; i = i + 1
    cval[#cval + 1] = conv[t] or ('Unknown (' .. str(t) .. ')')
    while i <= #vals do
        t = vals[i]; i = i + 1
        local v = vals[i]; i = i + 1
        if t ~= 0 then
            if v == nil then break end
            local c = filterSettings[t]
            if c then
                local c1 = c[2]
                if type(c1) == 'table' then
                    v = c1[v] or ('Unknown(' .. str(v) .. ')')
                elseif v ~= 0 then
                    v = sprintf(c1, v)
                end
                cval[#cval + 1] = c[1] .. '=' .. str(v)
            else
                cval[#cval + 1] = 'Unknown(' .. str(t) .. ')=' .. str(v)
            end
        end
    end
    return #cval > 0 and cval or nil
end

--------------------------------------------------------------------------------
-- Print K-3III AF Point names (ref PH)
-- Inputs: 0) value, 1) ExifTool ref, 2) optional value to match
local function AFPointNamesK3III(val, _et, match)
    local a = {}
    for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = tonumber(w) end
    local pts = {}
    if match then
        for i = 1, #a do
            if a[i] == match then pts[#pts + 1] = k3iiiAF[i] or ('Unknown(' .. (i - 1) .. ')') end
        end
    else
        for i = 1, #a do
            if a[i] ~= 0 then pts[#pts + 1] = k3iiiAF[i] or ('Unknown(' .. (i - 1) .. ')') end
        end
    end
    if #pts == 0 then return '(none)' end
    tsort(pts)
    return table.concat(pts, ',')
end

--------------------------------------------------------------------------------
-- Print K-3III AF point values (ref PH)
-- Inputs: 0) value, 1) ExifTool ref
-- Notes: this is experimental and not well understood
local function AFPointValuesK3III(val, _et)
    local a = {}
    for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = tonumber(w) end
    local vals = {}
    -- (I really don't understand why Pentax seemed to use 28 instead of 41 for
    -- the first index of the 2nd value, because as it stands there is
    -- overlap between the ranges of the 1st and 2nd values, and there is
    -- no way to tell which is which for cases were multiple points have values)
    for i = 1, #a do
        if a[i] and a[i] ~= 0 then
            local pt = k3iiiAF[i] and (k3iiiAF[i] .. '=') or (k3iiiAF[i - 28] .. '=/')
            vals[#vals + 1] = pt .. a[i]
            if a[i + 28] and a[i + 28] ~= 0 then
                vals[#vals] = vals[#vals] .. '/' .. a[i + 28]
                a[i + 28] = nil
            end
        end
    end
    if #vals == 0 then return '(none)' end
    tsort(vals)
    return table.concat(vals, ',')
end

--------------------------------------------------------------------------------
-- Print K-3III AF point positions from tag 0x040c (ref KG)
-- Inputs: 0) raw value, 1) ExifTool ref
local function AFAreasK3III(val, _et)
    if not ExifTool.perlTruthy(val) then return '(none)' end
    local vals = {}
    for w in str(val):gmatch('[^ \t\n\r\f\v]+') do vals[#vals + 1] = tonumber(w) end
    -- flags bits: [mask, value, description]
    local flags = { { 0x10, 0x10, 'central' }, { 0x08, 0, 'peripheral' }, { 0x04, 0x04, 'in-focus' } }
    local strs = {}
    local i = 0
    while i + 7 <= #vals do
        local a = {}
        for _, f in ipairs(flags) do
            if (vals[i + 7] & f[1]) == f[2] then a[#a + 1] = f[3] end
        end
        strs[#strs + 1] = vals[i + 3] .. ',' .. vals[i + 4] ..
            (#a > 0 and ('(' .. table.concat(a, ',') .. ')') or '')
        i = i + 7
    end
    return strs
end

--------------------------------------------------------------------------------
-- Decode AF points (upstream DecodeAFPoints)
-- Inputs: 0) AF point data, 1) number of AF points, 2) bits per AF point,
--         3) bit mask, 4) optional bit value
-- Returns: list of AF points
local function DecodeAFPoints(val, num, bits, mask, bitVal)
    local bytes = {}
    for w in str(val):gmatch('[^ \t\n\r\f\v]+') do bytes[#bytes + 1] = tonumber(w) end
    if #bytes == 0 then return '(none)' end
    local i = 1  -- (starts at AF point number 1)
    local shift = 8 - bits
    local nextByte = 2
    local byte = bytes[1]
    local bitList = {}
    while true do
        if bitVal then
            if ((byte >> shift) & mask) == bitVal then bitList[#bitList + 1] = i end
        else
            if ((byte >> shift) & mask) ~= 0 then bitList[#bitList + 1] = i end
        end
        i = i + 1
        if i > num then break end
        shift = shift - bits
        if shift < 0 then
            if nextByte > #bytes then break end
            byte = bytes[nextByte]
            nextByte = nextByte + 1
            shift = shift + 8
        end
    end
    return table.concat(bitList, ',')
end

-- Pentax makernote tags
Pentax.Main = {
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    WRITABLE = 1,
    [0x0000] = { -- #5
        Name = 'PentaxVersion',
        Writable = 'int8u',
        Count = 4,
        PrintConv = function(_self, val) return (str(val):gsub(' ', '.')) end,
        PrintConvInv = function(_self, val) return (perl.tr(val, '.', ' ')) end,
    },
    [0x0001] = { -- #PH
        Name = 'PentaxModelType',
        Writable = 'int16u',
    },
    [0x0002] = { -- #PH
        Name = 'PreviewImageSize',
        Groups = { [2] = 'Image' },
        Writable = 'int16u',
        Count = 2,
        PrintConv = function(_self, val) return (str(val):gsub(' ', 'x')) end,
        PrintConvInv = function(_self, val) return (perl.tr(val, 'x', ' ')) end,
    },
    [0x0003] = { -- #PH
        Name = 'PreviewImageLength',
        OffsetPair = 0x0004, -- point to associated offset
        DataTag = 'PreviewImage',
        Groups = { [2] = 'Image' },
        Writable = 'int32u',
        WriteGroup = 'MakerNotes',
        Protected = 2,
    },
    [0x0004] = { -- #PH
        Name = 'PreviewImageStart',
        IsOffset = 2, -- code to use original base
        OffsetPair = 0x0003, -- point to associated byte count
        DataTag = 'PreviewImage',
        Groups = { [2] = 'Image' },
        Writable = 'int32u',
        WriteGroup = 'MakerNotes',
        Protected = 2,
    },
    [0x0005] = { -- #13
        Name = 'PentaxModelID',
        Writable = 'int32u',
        PrintHex = 1,
        SeparateTable = 1,
        DataMember = 'PentaxModelID',
        RawConv = function(self, val) self.PentaxModelID = val; return val end,
        PrintConv = pentaxModelID,
    },
    [0x0006] = { -- #5
        -- Note: Year is int16u in MM byte ordering regardless of EXIF byte order
        Name = 'Date',
        Groups = { [2] = 'Time' },
        Notes = 'changing either Date or Time will affect ShutterCount decryption',
        Writable = 'undef',
        Count = 4,
        Shift = 'Time',
        DataMember = 'PentaxDate',
        RawConv = function(self, val) self.PentaxDate = str(val); return val end,
        ValueConv = function(_self, val)
            val = str(val)
            if #val ~= 4 then return 'Unknown (' .. val .. ')' end
            local y1, y2, m, d = val:byte(1, 4)
            return sprintf('%.4d:%.2d:%.2d', y1 * 256 + y2, m, d)
        end,
        ValueConvInv = function(_self, val)
            val = subst(val, [[(\d) .*]], '$1')          -- remove Time
            local v = perl.split(':', val)
            return pack_('nC2', v[1], v[2], v[3])
        end,
    },
    [0x0007] = { -- #5
        Name = 'Time',
        Groups = { [2] = 'Time' },
        Writable = 'undef',
        Count = 3,
        Shift = 'Time',
        DataMember = 'PentaxTime',
        RawConv = function(self, val) self.PentaxTime = str(val); return val end,
        ValueConv = function(_self, val)
            val = str(val)
            if #val < 3 then return 'Unknown (' .. val .. ')' end
            local h, mi, s = val:byte(1, 3)
            return sprintf('%.2d:%.2d:%.2d', h, mi, s)
        end,
        ValueConvInv = function(_self, val)
            val = subst(val, [[^[0-9:]+ (\d)]], '$1')    -- remove Date
            return pack_('C3', table.unpack(perl.split(':', val)))
        end,
    },
    [0x0008] = { -- #2
        Name = 'Quality',
        Writable = 'int16u',
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'Good',
            [1] = 'Better',
            [2] = 'Best',
            [3] = 'TIFF', -- #5
            [4] = 'RAW', -- #5
            [5] = 'Premium', -- #PH (K20D)
            [7] = 'RAW (pixel shift enabled)', -- #forum6536 (K-3 II)
            [8] = 'Dynamic Pixel Shift', -- #IB
            [9] = 'Monochrome', -- #github226
            [65535] = 'n/a', -- #PH (Q MOV video)
        },
    },
    [0x0009] = { -- #3
        Name = 'PentaxImageSize',
        Groups = { [2] = 'Image' },
        Writable = 'int16u',
        PrintConvColumns = 2,
        PrintConv = {
            [0] = '640x480',
            [1] = 'Full', -- #PH - this can mean 2048x1536 or 2240x1680 or ... ?
            [2] = '1024x768',
            [3] = '1280x960', -- #PH (Optio WP)
            [4] = '1600x1200',
            [5] = '2048x1536',
            [8] = '2560x1920 or 2304x1728', -- #PH (Optio WP) or #14
            [9] = '3072x2304', -- #PH (Optio M30)
            [10] = '3264x2448', -- #13
            [19] = '320x240', -- #PH (Optio WP)
            [20] = '2288x1712', -- #13
            [21] = '2592x1944',
            [22] = '2304x1728 or 2592x1944', -- #2 or #14
            [23] = '3056x2296', -- #13
            [25] = '2816x2212 or 2816x2112', -- #13 or #14
            [27] = '3648x2736', -- #PH (Optio A20)
            [29] = '4000x3000', -- #PH (X70)
            [30] = '4288x3216', -- #PH (Optio RS1000)
            [31] = '4608x3456', -- #PH (Optio RZ18)
            [129] = '1920x1080', -- #PH (Optio RZ10)
            [135] = '4608x2592', -- #PH (Q10 stretch filter)
            [257] = '3216x3216', -- #PH (Optio RZ10)
            ['0 0'] = '2304x1728', -- #13
            ['4 0'] = '1600x1200', -- #PH (Optio MX4)
            ['5 0'] = '2048x1536', -- #13
            ['8 0'] = '2560x1920', -- #13
            ['32 2'] = '960x640', -- #7
            ['33 2'] = '1152x768', -- #7
            ['34 2'] = '1536x1024', -- #7
            ['35 1'] = '2400x1600', -- #7
            ['36 0'] = '3008x2008 or 3040x2024',  -- #PH
            ['37 0'] = '3008x2000', -- #13
            -- 65535 - seen for an X-5 panorama (PH)
        },
    },
    [0x000b] = { -- #3
        Name = 'PictureMode',
        Writable = 'int16u',
        Count = -1,
        Notes = [[
            1 or 2 values.  Decimal values differentiate Optio 555 modes which are
            different from other models
        ]],
        ValueConv = function(self, val)
            if ExifTool.IsInt(val) and tonumber(val) < 4 and matches(str(self.Model or ''), [==[Optio 555\b]==]) then
                return tonumber(val) + 0.1
            end
            return val
        end,
        ValueConvInv = function(_self, val) return math.floor(tonumber(val)) end,
        PrintConvColumns = 2,
        PrintConv = { {
            [0] = 'Program', -- #PH
            [0.1] = 'Av', -- #PH (Optio 555)
            [1] = 'Shutter Speed Priority', -- #JD
            [1.1] = 'M', -- #PH (Optio 555)
            [2] = 'Program AE', -- #13
            [2.1] = 'Tv', -- #PH (Optio 555)
            [3] = 'Manual', -- #13
            [3.1] = 'USER', -- #PH (Optio 555)
            [5] = 'Portrait',
            [6] = 'Landscape',
            [8] = 'Sport', -- #PH
            [9] = 'Night Scene',
            -- 10 "full mode"? #13
            [11] = 'Soft', -- #PH
            [12] = 'Surf & Snow',
            [13] = 'Candlelight', -- #13
            [14] = 'Autumn',
            [15] = 'Macro',
            [17] = 'Fireworks',
            [18] = 'Text',
            [19] = 'Panorama', -- #PH
            [20] = '3-D', -- #PH (Optio 555)
            [21] = 'Black & White', -- #PH (Optio 555)
            [22] = 'Sepia', -- #PH (Optio 555)
            [23] = 'Red', -- #PH (Optio 555)
            [24] = 'Pink', -- #PH (Optio 555)
            [25] = 'Purple', -- #PH (Optio 555)
            [26] = 'Blue', -- #PH (Optio 555)
            [27] = 'Green', -- #PH (Optio 555)
            [28] = 'Yellow', -- #PH (Optio 555)
            [30] = 'Self Portrait', -- #PH
            [31] = 'Illustrations', -- #13
            [33] = 'Digital Filter', -- #13
            [35] = 'Night Scene Portrait', -- #NJ
            [37] = 'Museum', -- #PH
            [38] = 'Food', -- #PH
            [39] = 'Underwater', -- #NJ
            [40] = 'Green Mode', -- #PH
            [49] = 'Light Pet', -- #PH
            [50] = 'Dark Pet', -- #PH
            [51] = 'Medium Pet', -- #PH
            [53] = 'Underwater', -- #PH
            [54] = 'Candlelight', -- #PH
            [55] = 'Natural Skin Tone', -- #PH
            [56] = 'Synchro Sound Record', -- #PH
            [58] = 'Frame Composite', -- #14
            [59] = 'Report', -- #NJ
            [60] = 'Kids', -- #13
            [61] = 'Blur Reduction', -- #13
            [63] = 'Panorama 2', -- #PH (X-5)
            [65] = 'Half-length Portrait', -- #JD
            [66] = 'Portrait 2', -- #PH (LS645)
            [74] = 'Digital Microscope', -- #PH (WG-4)
            [75] = 'Blue Sky', -- #PH (LS465)
            [80] = 'Miniature', -- #PH (VS20)
            [81] = 'HDR', -- #PH (LS465)
            [83] = 'Fisheye', -- #PH (VS20)
            [85] = 'Digital Filter 4', -- #PH (WG-5)
            [221] = 'P', -- #PH (Optio 555)
            [255] = 'PICT', -- #PH (Optio 555)
        } },
    },
    [0x000c] = { -- #PH
        Name = 'FlashMode',
        Writable = 'int16u',
        Count = -1,
        PrintHex = 1,
        PrintConv = {
            {
                [0x000] = 'Auto, Did not fire',
                [0x001] = 'Off, Did not fire',
                [0x002] = 'On, Did not fire', -- #19
                [0x003] = 'Auto, Did not fire, Red-eye reduction',
                [0x005] = 'On, Did not fire, Wireless (Master)', -- #19
                [0x100] = 'Auto, Fired',
                [0x102] = 'On, Fired',
                [0x103] = 'Auto, Fired, Red-eye reduction',
                [0x104] = 'On, Red-eye reduction',
                [0x105] = 'On, Wireless (Master)', -- #19
                [0x106] = 'On, Wireless (Control)', -- #19
                [0x108] = 'On, Soft',
                [0x109] = 'On, Slow-sync',
                [0x10a] = 'On, Slow-sync, Red-eye reduction',
                [0x10b] = 'On, Trailing-curtain Sync',
            },{ -- #19 (AF-540FGZ flash)
                [0x000] = 'n/a - Off-Auto-Aperture', -- #19
                [0x03f] = 'Internal',
                [0x100] = 'External, Auto',
                [0x23f] = 'External, Flash Problem', -- #JD
                [0x300] = 'External, Manual',
                [0x304] = 'External, P-TTL Auto',
                [0x305] = 'External, Contrast-control Sync', -- #JD
                [0x306] = 'External, High-speed Sync',
                [0x30c] = 'External, Wireless',
                [0x30d] = 'External, Wireless, High-speed Sync',
            },
        },
    },
    [0x000d] = { -- #2
        {
            Name = 'FocusMode',
            -- (can't test for "PENTAX" because MOV videos don't have Make)
            Condition = function(self) return matches(self.Make, [[^Asahi]]) == nil end,
            Notes = 'Pentax models',
            Writable = 'int16u',
            PrintConvColumns = 2,
            PrintHex = 1,
            PrintConv = { -- #PH
                [0x00] = 'Normal',
                [0x01] = 'Macro',
                [0x02] = 'Infinity',
                [0x03] = 'Manual',
                [0x04] = 'Super Macro', -- #JD
                [0x05] = 'Pan Focus',
                [0x06] = 'Auto-area', -- (GR III)
                [0x07] = 'Zone Select', -- (GR III)
                [0x08] = 'Select', -- (GR III)
                [0x09] = 'Pinpoint', -- (GR III)
                [0x0a] = 'Tracking', -- (GR III)
                [0x0b] = 'Continuous', -- (GR III)
                [0x0c] = 'Snap', -- (GR III)
                [0x10] = 'AF-S (Focus-priority)', -- #17
                [0x11] = 'AF-C (Focus-priority)', -- #17
                [0x12] = 'AF-A (Focus-priority)', -- #PH (educated guess)
                [0x20] = 'Contrast-detect (Focus-priority)', -- #PH (K-5)
                [0x21] = 'Tracking Contrast-detect (Focus-priority)', -- #PH (K-5)
                -- bit 8 indicates release priority
                [0x110] = 'AF-S (Release-priority)', -- #PH (K-5,K-3)
                [0x111] = 'AF-C (Release-priority)', -- #PH (K-5,K-3)
                [0x112] = 'AF-A (Release-priority)', -- #PH (K-3)
                [0x120] = 'Contrast-detect (Release-priority)', -- #PH (K-01)
                -- bit 15 indicates macro mode (disabled for MF, and defaults to Select for Snap, Infinity)
                --  #KG 'disabled for MF' - in contradiction with 0x8003 ?? (one line upstream; wrapped at 160 columns)
                [0x8003] = 'Manual (Macro)', -- (GR IV)
                [0x8006] = 'Auto-area (Macro)', -- (GR III)
                [0x8007] = 'Zone Select (Macro)', -- (GR III)
                [0x8008] = 'Select (Macro)', -- (GR III)
                [0x8009] = 'Pinpoint (Macro)', -- (GR III)
                [0x800a] = 'Tracking (Macro)', -- (GR III)
                [0x800b] = 'Continuous (Macro)', -- (GR III)
            },
        }, {
            Name = 'FocusMode',
            Writable = 'int16u',
            Notes = 'Asahi models',
            PrintConv = { -- #2
                [0] = 'Normal',
                [1] = 'Macro (1)',
                [2] = 'Macro (2)',
                [3] = 'Infinity',
            },
        },
    },
    [0x000e] = { { -- #29
        Name = 'AFPointSelected',
        Condition = function(self) return matches(self.Model, [[(K-1|645Z)\b]]) ~= nil end, -- (NC for 645Z)
        Writable = 'int16u',
        Notes = 'K-1',
        PrintConvColumns = 2,
        PrintConv = { {
            [0xffff] = 'Auto',
            [0xfffe] = 'Fixed Center',
            [0xfffd] = 'Automatic Tracking AF', -- #JD
            [0xfffc] = 'Face Detect AF', -- #JD
            [0xfffb] = 'AF Select', -- #PH (Q select from 25-areas)
            -- AF pattern:
            --       01 02 03 04 05
            --    06 07 08 09 10 11 12
            -- 13 14 15 16 17 18 19 20 21
            --    22 23 24 25 26 27 28
            --       29 30 31 32 33
            [0] = 'None',
            [1] = 'Top-left',
            [2] = 'Top Near-left',
            [3] = 'Top',
            [4] = 'Top Near-right',
            [5] = 'Top-right',
            [6] = 'Upper Far-left',
            [7] = 'Upper-left',
            [8] = 'Upper Near-left',
            [9] = 'Upper-middle',
            [10] = 'Upper Near-right',
            [11] = 'Upper-right',
            [12] = 'Upper Far-right',
            [13] = 'Far Far Left',
            [14] = 'Far Left',
            [15] = 'Left',
            [16] = 'Near-left',
            [17] = 'Center',
            [18] = 'Near-right',
            [19] = 'Right',
            [20] = 'Far Right',
            [21] = 'Far Far Right',
            [22] = 'Lower Far-left',
            [23] = 'Lower-left',
            [24] = 'Lower Near-left',
            [25] = 'Lower-middle',
            [26] = 'Lower Near-right',
            [27] = 'Lower-right',
            [28] = 'Lower Far-right',
            [29] = 'Bottom-left',
            [30] = 'Bottom Near-left',
            [31] = 'Bottom',
            [32] = 'Bottom Near-right',
            [33] = 'Bottom-right',
            [263] = 'Zone Select Upper-left',       -- 01,02;06,07,08;14,15,16
            [264] = 'Zone Select Upper Near-left',  -- 01,02,03;07,08,09;15,16,17
            [265] = 'Zone Select Upper Middle',     -- 02,03,04;08,09,10;16,17,18
            [266] = 'Zone Select Upper Near-right', -- 03,04,05;09,10,11;17,18,19
            [267] = 'Zone Select Upper-right',      -- 04,05;10,11,12;18,19,20
            [270] = 'Zone Select Far Left',         -- 06,07;13,14,15;22,23
            [271] = 'Zone Select Left',             -- 06,07,08;14,15,16;22,23,24
            [272] = 'Zone Select Near-left',        -- 07,08,09;15,16,17;23,24,25
            [273] = 'Zone Select Center',           -- 08,09,10;16,17,18;24,25,26
            [274] = 'Zone Select Near-right',       -- 09,10,11;17,18,19;25,26,27
            [275] = 'Zone Select Right',            -- 10,11,12;18,19,20;26,27,28
            [276] = 'Zone Select Far Right',        -- 11,12;19,20,21;27,28
            [279] = 'Zone Select Lower-left',       -- 14,15,16;22,23,24;29,30
            [280] = 'Zone Select Lower Near-left',  -- 15,16,17;23,24,25;29,30,31
            [281] = 'Zone Select Lower-middle',     -- 16,17,18;24,25,26;30,31,32
            [282] = 'Zone Select Lower Near-right', -- 17,18,19;25,26,27;31,32,33
            [283] = 'Zone Select Lower-right',      -- 18,19,20;26,27,28;32,33
        }, {
            [0] = 'Single Point',
            [1] = 'Expanded Area 9-point (S)',
            [3] = 'Expanded Area 25-point (M)',
            [5] = 'Expanded Area 33-point (L)',
        } },
    }, {
        Name = 'AFPointSelected',
        Condition = function(self) return matches(self.Model, [[(K-3|KP)\b]]) ~= nil end,
        Writable = 'int16u',
        Notes = 'K-3',
        PrintConvColumns = 2,
        PrintConv = { {
            -- 0 - Contrast-detect AF? - PH (K-5)
            [0xffff] = 'Auto',
            [0xfffe] = 'Fixed Center',
            [0xfffd] = 'Automatic Tracking AF', -- #JD
            [0xfffc] = 'Face Detect AF', -- #JD
            [0xfffb] = 'AF Select', -- #PH (Q select from 25-areas)
            -- AF pattern: (ref forum5422)
            --    01 02 03 04 05
            --    06 07 08 09 10
            -- 11 12 13 14 15 16 17
            --    18 19 20 21 22
            --    23 24 25 26 27
            [0] = 'None',
            [1] = 'Top-left',
            [2] = 'Top Near-left',
            [3] = 'Top',
            [4] = 'Top Near-right',
            [5] = 'Top-right',
            [6] = 'Upper-left',
            [7] = 'Upper Near-left',
            [8] = 'Upper-middle',
            [9] = 'Upper Near-right',
            [10] = 'Upper-right',
            [11] = 'Far Left',
            [12] = 'Left',
            [13] = 'Near-left',
            [14] = 'Center',
            [15] = 'Near-right',
            [16] = 'Right',
            [17] = 'Far Right',
            [18] = 'Lower-left',
            [19] = 'Lower Near-left',
            [20] = 'Lower-middle',
            [21] = 'Lower Near-right',
            [22] = 'Lower-right',
            [23] = 'Bottom-left',
            [24] = 'Bottom Near-left',
            [25] = 'Bottom',
            [26] = 'Bottom Near-right',
            [27] = 'Bottom-right',
            -- #forum5892
            [257] = 'Zone Select Top-left',
            [258] = 'Zone Select Top Near-left',
            [259] = 'Zone Select Top',
            [260] = 'Zone Select Top Near-right',
            [261] = 'Zone Select Top-right',
            [262] = 'Zone Select Upper-left',
            [263] = 'Zone Select Upper Near-left',
            [264] = 'Zone Select Upper-middle',
            [265] = 'Zone Select Upper Near-right',
            [266] = 'Zone Select Upper-right',
            [267] = 'Zone Select Far Left',
            [268] = 'Zone Select Left',
            [269] = 'Zone Select Near-left',
            [270] = 'Zone Select Center',
            [271] = 'Zone Select Near-right',
            [272] = 'Zone Select Right',
            [273] = 'Zone Select Far Right',
            [274] = 'Zone Select Lower-left',
            [275] = 'Zone Select Lower Near-left',
            [276] = 'Zone Select Lower-middle',
            [277] = 'Zone Select Lower Near-right',
            [278] = 'Zone Select Lower-right',
            [279] = 'Zone Select Bottom-left',
            [280] = 'Zone Select Bottom Near-left',
            [281] = 'Zone Select Bottom',
            [282] = 'Zone Select Bottom Near-right',
            [283] = 'Zone Select Bottom-right',
        }, { -- #forum5892
            [0] = 'Single Point',
            [1] = 'Expanded Area 9-point (S)',
            [3] = 'Expanded Area 25-point (M)',
            [5] = 'Expanded Area 27-point (L)',
        } },
    }, { -- #7
        Name = 'AFPointSelected',
        Writable = 'int16u',
        Notes = 'other models',
        PrintConvColumns = 2,
        PrintConv = { {
            -- 0 - Contrast-detect AF? - PH (K-5)
            [0xffff] = 'Auto',
            [0xfffe] = 'Fixed Center',
            [0xfffd] = 'Automatic Tracking AF', -- #JD
            [0xfffc] = 'Face Detect AF', -- #JD
            [0xfffb] = 'AF Select', -- #PH (Q select from 25-areas)
            [0xfffa] = 'Auto 2', -- #KarstenGieselmann
            [0] = 'None', -- #PH (Q in manual focus mode)
            [1] = 'Upper-left',
            [2] = 'Top',
            [3] = 'Upper-right',
            [4] = 'Left',
            [5] = 'Mid-left',
            [6] = 'Center',
            [7] = 'Mid-right',
            [8] = 'Right',
            [9] = 'Lower-left',
            [10] = 'Bottom',
            [11] = 'Lower-right',
        }, {
        -- (second number exists for K-5II(s) is usually 0, but is 1 for AF.C with
        -- AFPointMode=='Select' and extended tracking focus points are enabled in the settings)
        -- -----
        -- #KG: for K-70 and older models with 11 PDAF points (K-S2, K-S1, K-50, K-500, K-30, K-5II(s) )
            [0] = 'Single Point',     -- Select AF (1-point) in both PDAF and CAF modes
            [1] = 'Expanded Area',    -- Expanded Area AF in AF-C
        } },
    } },
    [0x000f] = {
        { -- #PH
            Name = 'AFPointsInFocus',
            Condition = function(self) return matches(str(self.Model or ''), [==[K-(3|S1|S2)\b]==]) ~= nil end,  -- #KG: valid also for K-S1/S2
            Writable = 'int32u',
            Notes = 'K-3, K-S1 and K-S2 only',
            PrintHex = 1,
            PrintConv = {
                [0] = '(none)',
                BITMASK = {
                    [0] = 'Top-left',
                    [1] = 'Top Near-left',
                    [2] = 'Top',
                    [3] = 'Top Near-right',
                    [4] = 'Top-right',
                    [5] = 'Upper-left',
                    [6] = 'Upper Near-left',
                    [7] = 'Upper-middle',
                    [8] = 'Upper Near-right',
                    [9] = 'Upper-right',
                    [10] = 'Far Left',
                    [11] = 'Left',
                    [12] = 'Near-left',
                    [13] = 'Center',
                    [14] = 'Near-right',
                    [15] = 'Right',
                    [16] = 'Far Right',
                    [17] = 'Lower-left',
                    [18] = 'Lower Near-left',
                    [19] = 'Lower-middle',
                    [20] = 'Lower Near-right',
                    [21] = 'Lower-right',
                    [22] = 'Bottom-left',
                    [23] = 'Bottom Near-left',
                    [24] = 'Bottom',
                    [25] = 'Bottom Near-right',
                    [26] = 'Bottom-right',
                },
            },
        },
        { -- #PH
            Name = 'AFPointsInFocus',
            Notes = 'other models',
            Writable = 'int16u',
            PrintHex = 1,
            PrintConv = {
                [0xffff] = 'None',
                [0] = 'Fixed Center or Multiple', -- #PH/14
                [1] = 'Top-left',
                [2] = 'Top-center',
                [3] = 'Top-right',
                [4] = 'Left',
                [5] = 'Center',
                [6] = 'Right',
                [7] = 'Bottom-left',
                [8] = 'Bottom-center',
                [9] = 'Bottom-right',
            },
        },
    },
    [0x0010] = { -- #PH
        Name = 'FocusPosition',
        Writable = 'int16u',
        Notes = 'related to focus distance but affected by focal length',
    },
    [0x0012] = { -- #PH
        Name = 'ExposureTime',
        Writable = 'int32u',
        Priority = 0,
        ValueConv = function(_self, val) return val * 1e-5 end,
        ValueConvInv = function(_self, val) return val * 1e5 end,
        -- value may be 0xffffffff in Bulb mode (ref JD)
        PrintConv = function(_self, val)
            if val > 42949 then return 'Unknown (Bulb)' end
            return Exif.PrintExposureTime(val)
        end,
        PrintConvInv = function(_self, val)
            if perl.isMatch(val, '(?i)(unknown|bulb)') then return val end
            return Exif.ConvertFraction(val)
        end,
    },
    [0x0013] = { -- #PH
        Name = 'FNumber',
        Writable = 'int16u',
        Priority = 0,
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    -- ISO Tag - Entries confirmed by W. Smith 12 FEB 04
    [0x0014] = {
        Name = 'ISO',
        Writable = 'int16u',
        Notes = 'may be different than EXIF:ISO, which can round to the nearest full stop',
        PrintConvColumns = 4,
        PrintConv = {
            -- 1/3 EV step values
            [3] = 50,
            [4] = 64,
            [5] = 80,
            [6] = 100,
            [7] = 125, -- #PH
            [8] = 160, -- #PH
            [9] = 200,
            [10] = 250,
            [11] = 320, -- #PH
            [12] = 400,
            [13] = 500,
            [14] = 640,
            [15] = 800,
            [16] = 1000,
            [17] = 1250,
            [18] = 1600, -- #PH
            [19] = 2000, -- #PH
            [20] = 2500, -- #PH
            [21] = 3200, -- #PH
            [22] = 4000,
            [23] = 5000,
            [24] = 6400, -- #PH
            [25] = 8000, -- #PH
            [26] = 10000, -- #PH
            [27] = 12800, -- #PH
            [28] = 16000, -- #PH
            [29] = 20000, -- #PH
            [30] = 25600, -- #PH
            [31] = 32000, -- #PH
            [32] = 40000, -- #PH
            [33] = 51200, -- #PH
            [34] = 64000, -- #PH (NC)
            [35] = 80000, -- #PH (NC)
            [36] = 102400, -- #27
            [37] = 128000, -- #PH (NC)
            [38] = 160000, -- #PH (NC)
            [39] = 204800, -- #27
            [40] = 256000, -- #PH (NC)
            [41] = 320000, -- #PH (NC)
            [42] = 409600, -- #PH (NC)
            [43] = 512000, -- #PH (NC)
            [44] = 640000, -- #PH (NC)
            [45] = 819200, -- #PH (KP)
            -- Optio 330/430 (oddball)
            [50] = 50, -- #PH
            [100] = 100, -- #PH
            [200] = 200, -- #PH
            [400] = 400, -- #PH
            [800] = 800, -- #PH
            [1600] = 1600, -- #PH
            [3200] = 3200, -- #PH
            -- 1/2 EV step values
            [258] = 50, -- #PH (NC)
            [259] = 70, -- #PH (NC)
            [260] = 100, -- #19
            [261] = 140, -- #19
            [262] = 200, -- #19
            [263] = 280, -- #19
            [264] = 400, -- #19
            [265] = 560, -- #19
            [266] = 800, -- #19
            [267] = 1100, -- #19
            [268] = 1600, -- #19
            [269] = 2200, -- #PH
            [270] = 3200, -- #PH
            [271] = 4500, -- #PH
            [272] = 6400, -- #PH
            [273] = 9000, -- #PH
            [274] = 12800, -- #PH
            [275] = 18000, -- #PH
            [276] = 25600, -- #PH
            [277] = 36000, -- #PH
            [278] = 51200, -- #PH
            [279] = 72000, -- #PH (NC)
            [280] = 102400, -- #PH (NC)
            [281] = 144000, -- #PH (NC)
            [282] = 204800, -- #PH (NC)
            [283] = 288000, -- #PH (NC)
            [284] = 409600, -- #PH (NC)
            [285] = 576000, -- #PH (NC)
            [286] = 819200, -- #PH (NC)
            [65534] = 'Auto 2', -- #PH (Q/Q10/Q7 MOV) [how is this different from 65535?]
            [65535] = 'Auto', -- #PH/31 (K-01/K-70 MP4)
        },
    },
    [0x0015] = { -- #PH
        Name = 'LightReading',
        Format = 'int16s', -- (because I may have seen negative numbers)
        Writable = 'int16u',
        -- ranges from 0-12 for my Optio WP - PH
        Notes = [[
            calibrated differently for different models.  For the Optio WP, add 6 to get
            approximate Light Value.  May not be valid for some models, eg. Optio S
        ]],
    },
    [0x0016] = { { -- #PH
        Name = 'ExposureCompensation',
        Condition = function(_self, _val, _format, count) return count == 1 end,
        Notes = [[
            some models write two values here.  The second value is meaning of the
            second value is not yet known
        ]],
        Writable = 'int16u',
        ValueConv = function(_self, val) return (val - 50) / 10 end,
        ValueConvInv = function(_self, val) return math.floor(val * 10 + 50.5) end,
        PrintConv = function(_self, val) return ExifTool.perlTruthy(val) and sprintf('%+.1f', val) or 0 end,
        PrintConvInv = function(_self, val) return Exif.ConvertFraction(val) end,
    }, {
        Name = 'ExposureCompensation',
        Writable = 'int16u',
        -- (2 values for K-70, etc -- have only seen "0" for the 2nd value - PH)
        Count = 2,
        ValueConv = function(_self, val) val = perl.subst(val, ' .*', ''); return (val - 50) / 10 end,
        ValueConvInv = function(_self, val) return math.floor(val * 10 + 50.5) .. ' 0' end,
        PrintConv = function(_self, val) return ExifTool.perlTruthy(val) and sprintf('%+.1f', val) or 0 end,
        PrintConvInv = function(_self, val) return Exif.ConvertFraction(val) end,
    } },
    [0x0017] = { -- #3
        Name = 'MeteringMode',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Multi-segment',
            [1] = 'Center-weighted average',
            [2] = 'Spot',
            [6] = 'Highlight', -- (GR III)
        },
    },
    [0x0018] = { -- #PH
        Name = 'AutoBracketing',
        Writable = 'int16u',
        Count = -1,
        Notes = [[
            1 or 2 values: exposure bracket step in EV, then extended bracket if
            available.  Extended bracket values are printed as 'WB-BA', 'WB-GM',
            'Saturation', 'Sharpness', 'Contrast', 'Hue' or 'HighLowKey' followed by
            '+1', '+2' or '+3' for step size
        ]],
        -- 1=.3ev, 2=.7, 3=1.0 ... 10=.5, 11=1.5, ... 4096=0, 4097=0.5 ... 8192=0, 8193=0.3
        -- (models like K-1 and K-5 use 0x1000 and 0x2000 to indicate 1/2 and 1/3 EV step
        -- size -- convert this as a fraction so we can recognize this format when writing)
        ValueConv = { function(_self, val)
            val = tonumber(val)
            if val < 10 then return val / 3 end
            if val < 20 then return val - 9.5 end
            if val & 0x1000 ~= 0 then return (val - 0x1000) .. '/2' end
            if val & 0x2000 ~= 0 then return (val - 0x2000) .. '/3' end
            return val -- (shouldn't happen)
        end },
        ValueConvInv = { function(_self, val)
            local d = matches(val, [[/(\d+)$]])
            if d then
                val = subst(val, [[/(\d+)$]], '')
                if tonumber(d) == 2 then return val + 0x1000 end
                if tonumber(d) == 3 then return val + 0x2000 end
                return nil
            end
            if math.abs(val - perl.int(val) - 0.5) > 0.05 then return perl.int(val * 3 + 0.5) end
            return perl.int(val + 10)
        end },
        PrintConv = function(_self, val)
            local v = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do v[#v + 1] = w end
            if v[1] and v[1] ~= '0' and not v[1]:find('/') then
                v[1] = sprintf('%.1f', tonumber(v[1]))
            end
            if v[2] and v[2] ~= '0' then
                local s = { [1] = 'WB-BA', [2] = 'WB-GM', [3] = 'Saturation', [4] = 'Sharpness',
                            [5] = 'Contrast', [6] = 'Hue', [7] = 'HighLowKey' }
                local n = tonumber(v[2])
                local t = n >> 8
                v[2] = sprintf('%s+%d', s[t] or ('Unknown(' .. t .. ')'), n & 0xff)
            elseif v[2] then
                v[2] = 'No Extended Bracket'
            end
            return table.concat(v, ' EV, ')
        end,
        PrintConvInv = function(_self, val)
            local v = perl.split(', ?', val)
            v[1] = subst(v[1], [[(?i) ?EV]], '')
            if perl.truthy(v[2]) then
                local s = { ['WB-BA'] = 1, ['WB-GM'] = 2, Saturation = 3, Sharpness = 4,
                            Contrast = 5, Hue = 6, HighLowKey = 7 }
                local u1, u2 = matches(v[2], [[(?i)Unknown\((\d+)\)\+(\d+)]])
                local w1, w2 = matches(v[2], [[([\w-]+)\+(\d+)]])
                if perl.isMatch(v[2], [[(?i)^No\b]]) then
                    v[2] = 0
                elseif u1 then
                    v[2] = (perl.int(u1) << 8) + u2
                elseif w1 and s[w1] then
                    v[2] = (s[w1] << 8) + w2
                else
                    error("Bad extended bracket\n", 0)
                end
            end
            return perl.join(' ', v)
        end,
    },
    [0x0019] = { -- #3
        Name = 'WhiteBalance',
        Writable = 'int16u',
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'Auto', [1] = 'Daylight', [2] = 'Shade', [3] = 'Fluorescent', -- #2
            [4] = 'Tungsten', [5] = 'Manual', [6] = 'Daylight Fluorescent', -- #13
            [7] = 'Day White Fluorescent', -- #13
            [8] = 'White Fluorescent', -- #13
            [9] = 'Flash', -- #13
            [10] = 'Cloudy', -- #13
            [11] = 'Warm White Fluorescent', -- #PH (K-3)
            [14] = 'Multi Auto', -- #PH (K-3)
            [15] = 'Color Temperature Enhancement', -- #PH
            [17] = 'Kelvin', -- #PH
            [0xfffe] = 'Unknown', -- #13
            [0xffff] = 'User-Selected', -- #13
        },
    },
    [0x001a] = { -- #5
        Name = 'WhiteBalanceMode',
        Writable = 'int16u',
        PrintConv = {
            [1] = 'Auto (Daylight)',
            [2] = 'Auto (Shade)',
            [3] = 'Auto (Flash)',
            [4] = 'Auto (Tungsten)',
            [6] = 'Auto (Daylight Fluorescent)', -- #19 (NC)
            [7] = 'Auto (Day White Fluorescent)', -- #17 (K100D guess)
            [8] = 'Auto (White Fluorescent)', -- #17 (K100D guess)
            [10] = 'Auto (Cloudy)', -- #17 (K100D guess)
            [0xfffe] = 'Unknown', -- #PH (you get this when shooting night sky shots)
            [0xffff] = 'User-Selected',
        },
    },
    [0x001b] = { -- #6
        Name = 'BlueBalance',
        Writable = 'int16u',
        ValueConv = function(_self, val) return val / 256 end,
        ValueConvInv = function(_self, val) return math.floor(val * 256 + 0.5) end,
    },
    [0x001c] = { -- #6
        Name = 'RedBalance',
        Writable = 'int16u',
        ValueConv = function(_self, val) return val / 256 end,
        ValueConvInv = function(_self, val) return math.floor(val * 256 + 0.5) end,
    },
    [0x001d] = {
        -- Would be nice if there was a general way to determine units for FocalLength...
        {
            -- Optio 30, 33WR, 43WR, 450, 550, 555, 750Z, X
            Name = 'FocalLength',
            Condition = function(self) return matches(self.Model, [[^PENTAX Optio (30|33WR|43WR|450|550|555|750Z|X)\b]]) ~= nil end,
            Writable = 'int32u',
            Priority = 0,
            ValueConv = function(_self, val) return val / 10 end,
            ValueConvInv = function(_self, val) return val * 10 end,
            PrintConv = function(_self, val) return sprintf('%.1f mm', val) end,
            PrintConvInv = function(_self, val) val = perl.subst(val, [[\s*mm]], ''); return val end,
        },
        {
            -- K100D, Optio 230, 330GS, 33L, 33LF, A10, M10, MX, MX4, S, S30,
            -- S4, S4i, S5i, S5n, S5z, S6, S45, S50, S55, S60, SV, Svi, W10, WP,
            -- *ist D, DL, DL2, DS, DS2
            -- (Note: the Optio S6 seems to report the minimum focal length - PH)
            Name = 'FocalLength',
            Writable = 'int32u',
            Priority = 0,
            ValueConv = function(_self, val) return val / 100 end,
            ValueConvInv = function(_self, val) return val * 100 end,
            PrintConv = function(_self, val) return sprintf('%.1f mm', val) end,
            PrintConvInv = function(_self, val) val = perl.subst(val, [[\s*mm]], ''); return val end,
        },
    },
    [0x001e] = { -- #3
        Name = 'DigitalZoom',
        Writable = 'int16u',
        ValueConv = function(_self, val) return val / 100 end, -- #14
        ValueConvInv = function(_self, val) return val * 100 end, -- #14
    },
    [0x001f] = {
        Name = 'Saturation',
        Writable = 'int16u',
        Count = -1,
        Notes = '1 or 2 values',
        PrintConvColumns = 2,
        PrintConv = { { -- the *istD has pairs of values - PH
            [0] = '-2 (low)', -- #PH
            [1] = '0 (normal)', -- #PH
            [2] = '+2 (high)', -- #PH
            [3] = '-1 (medium low)', -- #2
            [4] = '+1 (medium high)', -- #2
            [5] = '-3 (very low)', -- #PH
            [6] = '+3 (very high)', -- #PH (NC)
            [7] = '-4 (minimum)', -- #PH (NC)
            [8] = '+4 (maximum)', -- #PH (K-5)
            [65535] = 'None', -- #PH (Monochrome)
        } },
    },
    [0x0020] = {
        Name = 'Contrast',
        Writable = 'int16u',
        Count = -1,
        Notes = '1 or 2 values',
        PrintConvColumns = 2,
        PrintConv = { { -- the *istD has pairs of values - PH
            [0] = '-2 (low)', -- #PH
            [1] = '0 (normal)', -- #PH
            [2] = '+2 (high)', -- #PH
            [3] = '-1 (medium low)', -- #2
            [4] = '+1 (medium high)', -- #2
            [5] = '-3 (very low)', -- #PH
            [6] = '+3 (very high)', -- #PH (NC)
            [7] = '-4 (minimum)', -- #PH (NC)
            [8] = '+4 (maximum)', -- #PH (K-5)
            [65535] = 'n/a', -- got this for a Backlight Silhouette - PH (Q)
        } },
    },
    [0x0021] = {
        Name = 'Sharpness',
        Writable = 'int16u',
        Count = -1,
        Notes = '1 or 2 values',
        PrintConvColumns = 2,
        PrintConv = { { -- the *istD has pairs of values - PH
            [0] = '-2 (soft)', -- #PH
            [1] = '0 (normal)', -- #PH
            [2] = '+2 (hard)', -- #PH
            [3] = '-1 (medium soft)', -- #2
            [4] = '+1 (medium hard)', -- #2
            [5] = '-3 (very soft)', -- #(NC)
            [6] = '+3 (very hard)', -- #(NC)
            [7] = '-4 (minimum)', -- #PH (NC)
            [8] = '+4 (maximum)', -- #PH (NC)
        } },
    },
    [0x0022] = { -- #PH
        Name = 'WorldTimeLocation',
        Groups = { [2] = 'Time' },
        Writable = 'int16u',
        PrintConv = { [0] = 'Hometown', [1] = 'Destination' },
    },
    [0x0023] = { -- #PH
        Name = 'HometownCity',
        Groups = { [2] = 'Time' },
        Writable = 'int16u',
        SeparateTable = 'City',
        PrintConv = pentaxCities,
    },
    [0x0024] = { -- #PH
        Name = 'DestinationCity',
        Groups = { [2] = 'Time' },
        Writable = 'int16u',
        SeparateTable = 'City',
        PrintConv = pentaxCities,
    },
    [0x0025] = { -- #PH
        Name = 'HometownDST',
        Groups = { [2] = 'Time' },
        Writable = 'int16u',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0x0026] = { -- #PH
        Name = 'DestinationDST',
        Groups = { [2] = 'Time' },
        Writable = 'int16u',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0x0027] = { -- #PH
        Name = 'DSPFirmwareVersion',
        Writable = 'undef',
        ValueConv = pentaxFirmwareID.ValueConv,
        ValueConvInv = pentaxFirmwareID.ValueConvInv,
        PrintConv = pentaxFirmwareID.PrintConv,
        PrintConvInv = pentaxFirmwareID.PrintConvInv,
    },
    [0x0028] = { -- #PH
        Name = 'CPUFirmwareVersion',
        Writable = 'undef',
        ValueConv = pentaxFirmwareID.ValueConv,
        ValueConvInv = pentaxFirmwareID.ValueConvInv,
        PrintConv = pentaxFirmwareID.PrintConv,
        PrintConvInv = pentaxFirmwareID.PrintConvInv,
    },
    [0x0029] = { -- #5
        Name = 'FrameNumber',
        -- - one report that this has a value of 84 for the first image with a *istDS
        -- - another report that file number 4 has frameNumber 154 for *istD, and
        --   that framenumber jumped at about 9700 to around 26000
        -- - with *istDS firmware 2.0, this tag was removed and ShutterCount was added
        Writable = 'int32u',
    },
    [0x002d] = { { -- #PH
        Name = 'EffectiveLV',
        Condition = function(_self, _val, format) return format == 'int16u' end,
        Notes = 'camera-calculated light value, but includes exposure compensation',
        Writable = 'int16u',
        Format = 'int16s', -- (negative values are valid even though Pentax writes int16u)
        ValueConv = function(_self, val) return val / 1024 end,
        ValueConvInv = function(_self, val) return val * 1024 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    }, {
        Name = 'EffectiveLV',
        Condition = function(_self, _val, format) return format == 'int32u' end,
        Writable = 'int32u',
        Format = 'int32s',
        ValueConv = function(_self, val) return val / 1024 end,
        ValueConvInv = function(_self, val) return val * 1024 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    } },
    [0x0032] = { -- #13
        Name = 'ImageEditing',
        Writable = 'undef',
        Format = 'int8u',
        Count = 4,
        PrintConv = {
            ['0 0'] = 'None', -- #PH
            ['0 0 0 0'] = 'None',
            ['0 0 0 4'] = 'Digital Filter',
            ['1 0 0 0'] = 'Resized', -- #PH (K-5)
            ['2 0 0 0'] = 'Cropped', -- #PH
            ['4 0 0 0'] = 'Digital Filter 4', -- #PH (K10D, Ricoh WG-5)
            ['6 0 0 0'] = 'Digital Filter 6', -- #PH (K-5)
            ['8 0 0 0'] = 'Red-eye Correction', -- #PH (WG-10)
            ['16 0 0 0'] = 'Frame Synthesis?',
        },
    },
    [0x0033] = { -- #PH (K110D/K100D/K-m)
        Name = 'PictureMode',
        Writable = 'int8u',
        Count = 3,
        Relist = { { 0, 1 }, 2 }, -- join values 0 and 1 for PrintConv
        PrintConvColumns = 2,
        PrintConv = {
            {
                -- Program dial modes (from K110D)
                ['0 0']  = 'Program',    -- (also on K10D, custom settings: Program Line 1, e-dial in Program 3, 4 or 5)
                ['0 1']  = 'Hi-speed Program', -- #19 (K10D, custom settings: Program Line 2, e-dial in Program 3, 4 or 5)
                ['0 2']  = 'DOF Program', -- #19      (K10D, custom settings: Program Line 3, e-dial in Program 3, 4 or 5)
                ['0 3']  = 'MTF Program', -- #19      (K10D, custom settings: Program Line 4, e-dial in Program 3, 4 or 5)
                ['0 4']  = 'Standard', -- #13
                ['0 5']  = 'Portrait',
                ['0 6']  = 'Landscape',
                ['0 7']  = 'Macro',
                ['0 8']  = 'Sport',
                ['0 9']  = 'Night Scene Portrait',
                ['0 10'] = 'No Flash',
                -- SCN modes (menu-selected) (from K100D)
                ['0 11'] = 'Night Scene',
                ['0 12'] = 'Surf & Snow',
                ['0 13'] = 'Text',
                ['0 14'] = 'Sunset',
                ['0 15'] = 'Kids',
                ['0 16'] = 'Pet',
                ['0 17'] = 'Candlelight',
                ['0 18'] = 'Museum',
                ['0 19'] = 'Food',
                ['0 20'] = 'Stage Lighting',
                ['0 21'] = 'Night Snap',
                ['0 23'] = 'Blue Sky', -- (Q)
                ['0 24'] = 'Sunset', -- (Q)
                ['0 26'] = 'Night Scene HDR', -- (Q)
                ['0 27'] = 'HDR', -- (Q)
                ['0 28'] = 'Quick Macro', -- (Q)
                ['0 29'] = 'Forest', -- (Q)
                ['0 30'] = 'Backlight Silhouette', -- (Q)
                ['0 31'] = 'Max. Aperture Priority', -- #KG (Ricoh GR III)
                ['0 32'] = 'DOF', -- #PH (GR III)       #KG ???? GR III 'DOF Priority (Deep)' is mapped to '0 2' ???
                -- AUTO PICT modes (auto-selected)
                ['1 4']  = 'Auto PICT (Standard)', -- #13
                ['1 5']  = 'Auto PICT (Portrait)', -- #7 (K100D)
                ['1 6']  = 'Auto PICT (Landscape)', -- K110D
                ['1 7']  = 'Auto PICT (Macro)', -- #13
                ['1 8']  = 'Auto PICT (Sport)', -- #13
                -- *istD modes (ref 7)
                ['2 0']  = 'Program (HyP)', -- #13 (K-5 Normal program line - PH)
                ['2 1']  = 'Hi-speed Program (HyP)', -- #19 (K10D, custom settings: Program Line 2, e-dial in Program 1, 2)
                ['2 2']  = 'DOF Program (HyP)', -- #19      (K10D, custom settings: Program Line 3, e-dial in Program 1, 2)
                ['2 3']  = 'MTF Program (HyP)', -- #19      (K10D, custom settings: Program Line 4, e-dial in Program 1, 2)
                ['2 22'] = 'Shallow DOF (HyP)', -- #PH (K-5)
                ['3 0']  = 'Green Mode', -- #16
                ['4 0']  = 'Shutter Speed Priority',
                ['4 2']  = 'Shutter Speed Priority 2', -- #KG  Coding error? 'DOF Priority' in Tv makes no sense
                ['4 31'] = 'Shutter Speed Priority 31', -- #KG  Coding error? 'Max Aperture' in Tv makes no sense
                ['5 0']  = 'Aperture Priority',
                ['5 2']  = 'Aperture Priority 2',      -- #KG  Coding error? 'DOF Priority' in Av makes no sense
                ['5 31'] = 'Aperture Priority 31',     -- #KG  Coding error? 'DOF Priority' in Av makes no sense
                ['6 0']  = 'Program Tv Shift',
                ['7 0']  = 'Program Av Shift', -- #19
                ['8 0']  = 'Manual',
                ['9 0']  = 'Bulb',
                ['10 0'] = 'Aperture Priority, Off-Auto-Aperture',
                ['11 0'] = 'Manual, Off-Auto-Aperture',
                ['12 0'] = 'Bulb, Off-Auto-Aperture',
                ['19 0'] = 'Astrotracer', -- #29
                -- extra K10D modes (ref 16)
                ['13 0'] = 'Shutter & Aperture Priority AE',
                ['14 0'] = 'Shutter Priority AE', -- #KG (K-3III))
                ['15 0'] = 'Sensitivity Priority AE',
                ['16 0'] = 'Flash X-Sync Speed AE',
                ['17 0'] = 'Flash X-Sync Speed', -- #KG (K-3III))
                ['18 0'] = 'Auto Program (Normal)', -- #PH (K-5)
                ['18 1'] = 'Auto Program (Hi-speed)', -- #PH (NC)
                ['18 2'] = 'Auto Program (DOF)', -- #PH (K-5)
                ['18 3'] = 'Auto Program (MTF)', -- #PH (NC)
                ['18 22'] = 'Auto Program (Shallow DOF)', -- #PH (NC)
                ['20 22'] = 'Blur Control', -- #PH (Q)
                ['24 0'] = 'Aperture Priority (Adv.Hyp)', -- #KG (K-3III)
                ['25 0'] = 'Manual Exposure (Adv.Hyp)', -- #KG (K-3III)
                ['26 0'] = 'Shutter and Aperture Priority (TAv)', -- #PH (K-3III)
                ['249 0'] = 'Movie (TAv)', -- #31
                ['250 0'] = 'Movie (TAv, Auto Aperture)', -- #31
                ['251 0'] = 'Movie (Manual)', -- #31
                ['252 0'] = 'Movie (Manual, Auto Aperture)', -- #31
                ['253 0'] = 'Movie (Av)', -- #31
                ['254 0'] = 'Movie (Av, Auto Aperture)', -- #31
                ['255 0'] = 'Movie (P, Auto Aperture)', -- #31
                ['255 4'] = 'Video (4)', -- #PH (K-x,K-01)
            },{
                -- EV step size (ref 19)
                [0] = '1/2 EV steps',
                [1] = '1/3 EV steps',
            },
        },
    },
    [0x0034] = { -- #7/PH
        Name = 'DriveMode',
        Writable = 'int8u',
        Count = 4,
        PrintConv = {
            {
                [0] = 'Single-frame',
                [1] = 'Continuous',
                [2] = 'Continuous (Lo)',
                [3] = 'Burst',
                [4] = 'Continuous (Medium)',
                [5] = 'Continuous (Low)',
                [255] = 'Video',
            },{
                [0] = 'No Timer',
                [1] = 'Self-timer (12 s)',
                [2] = 'Self-timer (2 s)',
                [15] = 'Video',
                [16] = 'Mirror Lock-up',
                [255] = 'n/a',
            },{
                [0] = 'Shutter Button',
                [1] = 'Remote Control (3 s delay)',
                [2] = 'Remote Control',
                [4] = 'Remote Continuous Shooting',
            },{
                [0x00] = 'Single Exposure',
                [0x01] = 'Multiple Exposure',
                [0x02] = 'Composite Average',
                [0x03] = 'Composite Additive',
                [0x04] = 'Composite Bright',
                [0x08] = 'Interval Shooting',
                [0x0a] = 'Interval Composite Average',
                [0x0b] = 'Interval Composite Additive',
                [0x0c] = 'Interval Composite Bright',
                [0x0f] = 'Interval Movie',
                [0x10] = 'HDR',
                [0x20] = 'HDR Strong 1',
                [0x30] = 'HDR Strong 2',
                [0x40] = 'HDR Strong 3',
                [0x50] = 'HDR Manual',
                [0xe0] = 'HDR Auto',
                [0xff] = 'Video',
            },
        },
    },
    [0x0035] = { -- #PH
        Name = 'SensorSize',
        Format = 'int16u',
        Count = 2,
        Notes = 'includes masked pixels',
        -- values for various models (not sure why this is in 2um increments):
        --  11894 7962 (K10D,K-m)   12012 7987 (*istDS,K100D,K110D)   12012 8019 (*istD),
        --  12061 7988 (K-5)        12053 8005 (K-r,K-x)              14352 9535 (K20D,K-7)
        --  22315 16711 (645)       12080 8008 (K-01)
        ValueConv = function(_self, val)
            local a = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = str(tonumber(w) / 500) end
            return table.concat(a, ' ')
        end,
        ValueConvInv = function(_self, val)
            local a = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = str(tonumber(w) * 500) end
            return table.concat(a, ' ')
        end,
        PrintConv = function(_self, val)
            local a = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = tonumber(w) end
            return sprintf('%.3f x %.3f mm', a[1], a[2])
        end,
        PrintConvInv = function(_self, val)
            return (str(val):gsub('[ \t\n\r\f\v]*mm$', ''):gsub('[ \t\n\r\f\v]*x[ \t\n\r\f\v]*', ' '))
        end,
    },
    [0x0037] = { -- #13
        Name = 'ColorSpace',
        Writable = 'int16u',
        PrintConv = { [0] = 'sRGB', [1] = 'Adobe RGB' },
    },
    [0x0038] = { -- #5 (PEF only)
        Name = 'ImageAreaOffset',
        Writable = 'int16u',
        Count = 2,
    },
    [0x0039] = { -- #PH
        Name = 'RawImageSize',
        Writable = 'int16u',
        Count = 2,
        PrintConv = function(_self, val) return (str(val):gsub(' ', 'x', 1)) end,
    },
    [0x003c] = { -- #7/PH
        Name = 'AFPointsInFocus',
        -- not writable because I'm not decoding these 4 bytes fully:
        -- Nibble pattern: XSSSYUUU
        -- X = unknown (AF focused flag?, 0 or 1)
        -- SSS = selected AF point bitmask (0x000 or 0x7ff if unused)
        -- Y = unknown (observed 0,6,7,b,e, always 0 if SSS is 0x000 or 0x7ff)
        -- UUU = af points used
        Format = 'int32u',
        Notes = '*istD only',
        ValueConv = function(_self, val) return val & 0x7ff end, -- ignore other bits for now
        PrintConvColumns = 2,
        PrintConv = {
            [0] = '(none)',
            BITMASK = {
                [0] = 'Upper-left',
                [1] = 'Top',
                [2] = 'Upper-right',
                [3] = 'Left',
                [4] = 'Mid-left',
                [5] = 'Center',
                [6] = 'Mid-right',
                [7] = 'Right',
                [8] = 'Lower-left',
                [9] = 'Bottom',
                [10] = 'Lower-right',
            },
        },
    },
    [0x003d] = { -- #IB
        Name = 'DataScaling',
        Writable = 'int16u',
    },
    [0x003e] = { -- #PH
        Name = 'PreviewImageBorders',
        Writable = 'int8u',
        Count = 4,
        Notes = 'top, bottom, left, right',
    },
    [0x003f] = { -- #PH
        Name = 'LensRec',
        SubDirectory = { TagTable = 'lexiftool.Pentax.LensRec' },
    },
    [0x0040] = { -- #PH
        Name = 'SensitivityAdjust',
        Writable = 'int16u',
        ValueConv = function(_self, val) return (val - 50) / 10 end,
        ValueConvInv = function(_self, val) return val * 10 + 50 end,
        PrintConv = function(_self, val) return val ~= 0 and sprintf('%+.1f', val) or 0 end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x0041] = { -- #19
        Name = 'ImageEditCount',
        Writable = 'int16u',
    },
    [0x0047] = { -- #PH
        Name = 'CameraTemperature', -- (chassis temperature, ref forum6677)
        Writable = 'int8s',
        PrintConv = function(_self, val) return perl.str(val) .. ' C' end,
        PrintConvInv = function(_self, val) return (subst(val, [[(?i) ?c$]], '')) end,
    },
    [0x0048] = { -- #19
        Name = 'AELock',
        Writable = 'int16u',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x0049] = { -- #13
        Name = 'NoiseReduction',
        Writable = 'int16u',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x004d] = { { -- #PH
        Name = 'FlashExposureComp',
        Condition = function(_self, _val, _format, count) return count == 1 end,
        Writable = 'int32s',
        ValueConv = function(_self, val) return val / 256 end,
        ValueConvInv = function(_self, val) local r = val * 256 + (val > 0 and 0.5 or -0.5); return r < 0 and math.ceil(r) or math.floor(r) end,
        PrintConv = function(_self, val) return ExifTool.perlTruthy(val) and sprintf('%+.1f', val) or 0 end,
        PrintConvInv = function(_self, val) return Exif.ConvertFraction(val) end,
    }, { -- #PH (K-3)
        Name = 'FlashExposureComp',
        Writable = 'int8s',
        Count = 2,     -- (don't know what the 2nd number is for)
        ValueConv = { function(_self, val) return val / 6 end },
        ValueConvInv = { function(_self, val) return val / 6 end },
        PrintConv = { function(_self, val) return ExifTool.perlTruthy(val) and sprintf('%+.1f', val) or 0 end },
        PrintConvInv = { function(_self, val) return Exif.ConvertFraction(val) end },
    } },
    [0x004f] = { -- #PH
        Name = 'ImageTone', -- (Called CustomImageMode for K20D and ImageControlMode for GR III)
        Writable = 'int16u',
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'Natural',
            [1] = 'Bright',
            [2] = 'Portrait', -- (K20D/K200D)
            [3] = 'Landscape', -- (K20D)
            [4] = 'Vibrant', -- (K20D)
            [5] = 'Monochrome', -- (K20D)
            [6] = 'Muted', -- (645D)
            [7] = 'Reversal Film', -- (645D) (Ricoh WG-5 "Slide Film")
            [8] = 'Bleach Bypass', -- (K-5)
            [9] = 'Radiant', -- (Q)
            [10] = 'Cross Processing', -- #31 (K-70)
            [11] = 'Flat', -- #31 (K-70)
            -- the following values from GR III
            [256] = 'Standard',
            [257] = 'Vivid',
            [258] = 'Monotone',
            [259] = 'Soft Monotone',
            [260] = 'Hard Monotone',
            [261] = 'Hi-contrast B&W',
            [262] = 'Positive Film',
            [263] = 'Bleach Bypass 2',
            [264] = 'Retro',
            [265] = 'HDR Tone',
            [266] = 'Cross Processing 2',
            [267] = 'Negative Film',
            -- 256 - seen for GR III
            -- 257 - seen for GR III
            -- 262 - seen for GR III
            [32768] = 'Standard', -- #KG (K-3IIIm) (was "n/a" previously - PH)
            [32769] = 'Hard', -- #KG (K-3IIIm)
            [32770] = 'Soft', -- #KG (K-3IIIm)
            [33024] = 'Monochrome', -- #forum17904 (GR IV Monochrome)
        },
    },
    [0x0050] = { -- #PH
        Name = 'ColorTemperature',
        Writable = 'int16u',
        RawConv = function(_self, val) return val ~= 0 and val or nil end,
        ValueConv = function(_self, val) return 53190 - val end,
        ValueConvInv = function(_self, val) return 53190 - val end,
    },
    [0x0053] = colorTemp { -- #28
        Name = 'ColorTempDaylight',
        Notes = '0x0053-0x005a are 3 numbers: Kelvin, shift AB, shift GM',
    },
    [0x0054] = colorTemp { Name = 'ColorTempShade' }, -- #28
    [0x0055] = colorTemp { Name = 'ColorTempCloudy' }, -- #28
    [0x0056] = colorTemp { Name = 'ColorTempTungsten' }, -- #28
    [0x0057] = colorTemp { Name = 'ColorTempFluorescentD' }, -- #28
    [0x0058] = colorTemp { Name = 'ColorTempFluorescentN' }, -- #28
    [0x0059] = colorTemp { Name = 'ColorTempFluorescentW' }, -- #28
    [0x005a] = colorTemp { Name = 'ColorTempFlash' }, -- #28
    [0x005c] = { { -- #PH
        Name = 'ShakeReductionInfo',
        Condition = function(_self, _val, _format, count) return count == 4 end, -- (2 bytes for the K-3)
        Format = 'undef', -- (written as int8u) - do this just to save time converting the value
        SubDirectory = { TagTable = 'lexiftool.Pentax.SRInfo' },
    }, {
        Name = 'ShakeReductionInfo',
        Format = 'undef', -- (written as int8u) - do this just to save time converting the value
        SubDirectory = { TagTable = 'lexiftool.Pentax.SRInfo2' },
    } },
    [0x005d] = { -- #JD/PH
        Name = 'ShutterCount',
        Writable = 'undef',
        Count = 4,
        Notes = [[
            Note: May be reset by servicing!  Also, does not include shutter actuations
            for live view or video recording
        ]],
        RawConv = function(_self, val)
            val = str(val)
            if #val ~= 4 then return nil end
            local a, b, c, d = val:byte(1, 4)
            return ((a * 256 + b) * 256 + c) * 256 + d
        end,
        RawConvInv = function(self, val)
            val = CryptShutterCount(val, self)
            return pack_('N', val)
        end,
        ValueConv = function(self, val) return CryptShutterCount(val, self) end,
        ValueConvInv = function(_self, val) return val end,
    },
    [0x0060] = { -- #PH (K-5)
        Name = 'FaceInfo',
        Format = 'undef', -- (written as int8u)
        SubDirectory = { TagTable = 'lexiftool.Pentax.FaceInfo' },
    },
    [0x0062] = { -- #forum4803
        Name = 'RawDevelopmentProcess',
        Condition = function(self) return matches(self.Make, [[^(PENTAX|RICOH)]]) ~= nil end,
        Writable = 'int16u',
        PrintConv = {
            [1] = '1 (K10D,K200D,K2000,K-m)',
            [3] = '3 (K20D)', [4] = '4 (K-7)', [5] = '5 (K-x)', [6] = '6 (645D)',
            [7] = '7 (K-r)', [8] = '8 (K-5,K-5II,K-5IIs)', [9] = '9 (Q)',
            [10] = '10 (K-01,K-30,K-50,K-500)', [11] = '11 (Q10)',
            [12] = '12 (MX-1,Q-S1,Q7)', [13] = '13 (K-3,K-3II)', [14] = '14 (645Z)',
            [15] = '15 (K-S1,K-S2)', [16] = '16 (K-1)', [17] = '17 (K-70)',
            [18] = '18 (KP)', [19] = '19 (GR III)', [20] = '20 (K-3III)',
            [21] = '21 (K-3IIIMonochrome)',
        },
    },
    [0x0067] = { -- #PH (K-5)
        Name = 'Hue',
        Writable = 'int16u',
        PrintConvColumns = 2,
        PrintConv = {
            [0] = -2, [1] = 'Normal', [2] = 2, [3] = -1, [4] = 1,
            [5] = -3, [6] = 3, [7] = -4, [8] = 4,
            [65535] = 'None', -- (Monochrome)
        },
    },
    [0x0068] = { -- #PH
        Name = 'AWBInfo',
        Format = 'undef', -- (written as int8u)
        SubDirectory = { TagTable = 'lexiftool.Pentax.AWBInfo' },
    },
    [0x0069] = { -- #PH (K20D, K-5, K-01 highlights only)
        Name = 'DynamicRangeExpansion',
        Notes = [[
            called highlight correction by Pentax for the K20D, K-5, K-01 and maybe
            other models
        ]],
        Writable = 'undef',
        Format = 'int8u',
        Count = 4,
        PrintConv = { {
            [0] = 'Off',
            [1] = 'On',
        }, {
            [0] = 0,
            [1] = 'Enabled', -- (K-01)
            [2] = 'Auto', -- (K-01)
        } },
    },
    [0x006b] = { -- #PH (K-5)
        Name = 'TimeInfo',
        Format = 'undef', -- (written as int8u)
        SubDirectory = { TagTable = 'lexiftool.Pentax.TimeInfo' },
    },
    [0x006c] = { -- #PH (K-5)
        Name = 'HighLowKeyAdj',
        Description = 'High/Low Key Adj',
        Writable = 'int16s',
        Count = 2,
        PrintConvColumns = 3,
        PrintConv = {
            ['-4 0'] = -4, ['-3 0'] = -3, ['-2 0'] = -2, ['-1 0'] = -1,
            ['0 0'] = 0, ['1 0'] = 1, ['2 0'] = 2, ['3 0'] = 3, ['4 0'] = 4,
        },
    },
    [0x006d] = { -- #PH (K-5)
        Name = 'ContrastHighlight',
        Writable = 'int16s',
        Count = 2,
        PrintConvColumns = 3,
        PrintConv = {
            ['-4 0'] = -4,
            ['-3 0'] = -3,
            ['-2 0'] = -2,
            ['-1 0'] = -1,
             ['0 0'] = 0,
             ['1 0'] = 1,
             ['2 0'] = 2,
             ['3 0'] = 3,
             ['4 0'] = 4,
        },
    },
    [0x006e] = { -- #PH (K-5)
        Name = 'ContrastShadow',
        Writable = 'int16s',
        Count = 2,
        PrintConvColumns = 3,
        PrintConv = {
            ['-4 0'] = -4,
            ['-3 0'] = -3,
            ['-2 0'] = -2,
            ['-1 0'] = -1,
             ['0 0'] = 0,
             ['1 0'] = 1,
             ['2 0'] = 2,
             ['3 0'] = 3,
             ['4 0'] = 4,
        },
    },
    [0x006f] = { -- #PH (K-5)
        Name = 'ContrastHighlightShadowAdj',
        Description = 'Contrast Highlight/Shadow Adj',
        Writable = 'int8u',
        PrintConv = {
            [0] = 'Off',
            [1] = 'On',
        },
    },
    [0x0070] = { -- #PH (K-5)
        Name = 'FineSharpness',
        Writable = 'int8u',
        Count = -1,    -- 1 for K20/K200, 2 for K-5
        PrintConv = { {
            [0] = 'Off',
            [1] = 'On',
        }, {
            [0] = 'Normal',
            [2] = 'Extra fine',
        } },
    },
    [0x0071] = { -- #PH (K20D,K-x)
        Name = 'HighISONoiseReduction',
        Format = 'int8u',
        PrintConv = { {
            [0] = 'Off',
            [1] = 'Weakest',
            [2] = 'Weak', -- (called "Low" by K-x)
            [3] = 'Strong', -- (called "High" by K-x)
            [4] = 'Medium',
            [255] = 'Auto', -- (K-5)
        }, {
            [0] = 'Inactive',
            [1] = 'Active',
            [2] = 'Active (Weak)', -- (K-5)
            [3] = 'Active (Strong)', -- (K-5)
            [4] = 'Active (Medium)', -- (K-5)
        }, { -- Start ISO level for NR (K-x)
            [48] = 'ISO>400',
            [56] = 'ISO>800',
            [64] = 'ISO>1600',
            [72] = 'ISO>3200',
        } },
    },
    [0x0072] = { -- #JD (K20D)
        Name = 'AFAdjustment',
        Writable = 'int16s',
    },
    [0x0073] = { -- #PH (K-5)
        Name = 'MonochromeFilterEffect',
        Writable = 'int16u',
        PrintConvColumns = 2,
        PrintConv = {
            [65535] = 'None',
            [1] = 'Green', [2] = 'Yellow', [3] = 'Orange', [4] = 'Red',
            [5] = 'Magenta', [6] = 'Blue', [7] = 'Cyan', [8] = 'Infrared',
        },
    },
    [0x0074] = { -- #PH (K-5)
        Name = 'MonochromeToning',
        Writable = 'int16u',
        PrintConvColumns = 2,
        PrintConv = {
            [65535] = 'None',
            [0] = -4,
            [1] = -3,
            [2] = -2,
            [3] = -1,
            [4] = 0,
            [5] = 1,
            [6] = 2,
            [7] = 3,
            [8] = 4,
        },
    },
    [0x0076] = { -- #PH (K-5)
        Name = 'FaceDetect',
        Writable = 'int8u',
        Count = 2,
        -- the Optio S12 writes this but not the FacesDetected tag, so get FacesDetected from here
        DataMember = 'FacesDetected',
        RawConv = function(self, val)
            local n = matches(str(val), [==[ (\d+)]==])
            if n then self.FacesDetected = n end
            return val
        end,
        -- (the K-3 reports "On" even in phase-detect focus modes)
        PrintConv = {
            function(_self, val)
                return ExifTool.perlTruthy(val) and ('On (' .. str(val) .. ' faces max)') or 'Off'
            end,
            function(_self, val) return str(val) .. ' faces detected' end,
        },
        PrintConvInv = {
            function(_self, val) return tonumber((matches(str(val), [==[(\d+)]==]))) or 0 end,
            function(_self, val) return tonumber((matches(str(val), [==[(\d+)]==]))) or 0 end,
        },
    },
    [0x0077] = { -- #PH (K-5)
        -- set by taking a picture with face detect AF,
        -- but it isn't reset until camera is turned off? - PH
        Name = 'FaceDetectFrameSize',
        Writable = 'int16u',
        Count = 2,
    },
    [0x0079] = { -- #PH
        Name = 'ShadowCorrection',
        Writable = 'int8u',
        Count = -1,
        PrintConvColumns = 2,
        PrintConv = {
            -- (1 value for K-m/K2000, 2 for 645D)
            [0] = 'Off',
            [1] = 'On',
            [2] = 'Auto 2', -- (NC, WG-3)
            ['0 0'] = 'Off',
            ['1 1'] = 'Weak',
            ['1 2'] = 'Normal',
            ['1 3'] = 'Strong',
            ['2 4'] = 'Auto', -- (K-01)
        },
    },
    [0x007a] = { -- #PH
        Name = 'ISOAutoMinSpeed',
        Writable = 'int8u',
        Count = 2,
        -- From the K-3III menus for the "ISO Auto with Min. Speed" setting: 'Fast' = "Increases
        -- the sensitivity from a shutter speed faster than the standard setting in ISO Auto"
        ValueConv    = { false,
            function(_self, val)
                return ExifTool.perlTruthy(val) and math.exp(-PentaxEv(val - 68) * math.log(2)) or 0
            end },
        ValueConvInv = { false,
            function(_self, val)
                return ExifTool.perlTruthy(val) and (PentaxEvInv(-math.log(val) / math.log(2)) + 68) or 0
            end },
        PrintConv    = {
            {
                [1] = 'Shutter Speed Control',
                [2] = 'Auto Slow',
                [3] = 'Auto Standard',
                [4] = 'Auto Fast',
            },
            function(_self, val) return Exif.PrintExposureTime(val) end,
        },
        PrintConvInv = { false, function(_self, val) return Exif.ConvertFraction(val) end },
    },
    [0x007b] = { -- #PH (K-5)
        Name = 'CrossProcess',
        Writable = 'int8u',
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'Off', [1] = 'Random', [2] = 'Preset 1', [3] = 'Preset 2',
            [4] = 'Preset 3', [33] = 'Favorite 1', [34] = 'Favorite 2', [35] = 'Favorite 3',
        },
    },
    [0x007d] = { -- #PH
        Name = 'LensCorr',
        Format = 'undef', -- (written as int8u)
        SubDirectory = { TagTable = 'lexiftool.Pentax.LensCorr' },
    },
    [0x007e] = { -- #IB
        Name = 'WhiteLevel', -- (with black level already subtracted)
        Writable = 'int32u',
        -- 15859,15860,15864,15865,16315 (K-5 PEF/DNG only) - PH
        -- 3934, 3935 (Q DNG) - PH
    },
    [0x007f] = { -- #PH (K-5)
        Name = 'BleachBypassToning',
        Writable = 'int16u',
        PrintConvColumns = 2,
        PrintConv = {
            [65535] = 'n/a', -- #31
            [0] = 'Off', -- #31
            [1] = 'Green',
            [2] = 'Yellow',
            [3] = 'Orange',
            [4] = 'Red',
            [5] = 'Magenta',
            [6] = 'Purple',
            [7] = 'Blue',
            [8] = 'Cyan',
        },
    },
    [0x0080] = { -- #PH (Q)
        Name = 'AspectRatio',
        PrintConv = {
            [0] = '4:3',
            [1] = '3:2',
            [2] = '16:9',
            [3] = '1:1',
        },
    },
    [0x0082] = {
        Name = 'BlurControl',
        Writable = 'int8u',
        Count = 4,
        PrintConv = {
            {
                [0] = 'Off',
                [1] = 'Low',
                [2] = 'Medium',
                [3] = 'High',
            },
            false, -- 0 with BlurControl is Off, seen 0,1,3 when on (related to subject distance?)
            false, -- 0 with BlurControl Off, 45 when on
            false, -- always 0
        },
    },
    [0x0085] = { -- #PH
        Name = 'HDR',
        Format = 'int8u',
        Count = 4,
        PrintConv = { { -- (K-01,K-3)
            [0] = 'Off',
            [1] = 'HDR Auto',
            [2] = 'HDR 1',
            [3] = 'HDR 2',
            [4] = 'HDR 3',
            [5] = 'HDR Advanced', -- #29 (K-1)
        }, { -- (K-01)
            [0] = 'Auto-align Off',
            [1] = 'Auto-align On',
        }, {
            -- not sure about this - PH
            -- - you can set HDR "Exposure Bracket Value" with the K-3
            -- - guessed from imaging-resource K-3 samples K3OUTBHDR_A{1,2,3}
            [0] = 'n/a',
            [4] = '1 EV',
            [8] = '2 EV',
            [12] = '3 EV', -- (get this from K-01, but can't set EV)
        },
        -- (4th number is always 0)
        },
    },
    [0x0087] = { -- #PH
        Name = 'ShutterType',
        Writable = 'int8u',
        PrintConv = {
            [0] = 'Normal', -- ('Mechanical' if the camera has a mechanical shutter)
            [1] = 'Electronic', -- (KP)
        },
    },
    [0x0088] = { -- #PH
        Name = 'NeutralDensityFilter',
        Writable = 'int8u',
        Count = -1,
        PrintConv = {
            [0] = 'Off',
            [1] = 'On',
            ['0 0'] = 'Off (Off)', -- #PH (GR III)
            ['1 1'] = 'On (On)', -- #PH (GR III)
            ['0 2'] = 'Off (Auto)', -- #PH (GR III)
            ['1 2'] = 'On (Auto)', -- #PH (GR III)
        },
    },
    [0x008b] = { -- #PH (LS465)
        Name = 'ISO',
        Priority = 0,
        Writable = 'int32u',
    },
    [0x0092] = { -- #31
        Name = 'IntervalShooting',
        Notes = '2 numbers: 1. Shot number 2. Total number of shots',
        Writable = 'int16u',
        Count = 2,
        PrintConv = {
            ['0 0'] = 'Off',
            OTHER = function(val)
                return (str(val):gsub('(%d+) (%d+)', 'Shot %1 of %2'))
            end,
        },
    },
    [0x0095] = {
        { -- #31
            Name = 'SkinToneCorrection',
            Condition = function(_self, _val, _format, count) return count == 2 end,
            Writable = 'int8s',
            Count = 2,
            PrintConv = {
                ['0 0'] = 'Off',
                ['1 1'] = 'On (type 1)',
                ['1 2'] = 'On (type 2)',
            },
        },
        {
            Name = 'SkinToneCorrection',
            Condition = function(_self, _val, _format, count) return count == 3 end,
            Writable = 'int8s',
            Count = 3,
            PrintConv = {
                ['0 0 0'] = 'Off',
            },
        },
    },
    [0x0096] = { -- #31
        Name = 'ClarityControl',
        Writable = 'int8s',
        Count = 2,
        PrintConv = {
            ['0 0'] = 'Off',
            OTHER = function(val)
                local n = str(val):match('^1 (%-?%d+)$')
                if n then
                    return tonumber(n) ~= 0 and sprintf('%+d', tonumber(n)) or 0
                end
                return 'Unknown (' .. str(val) .. ')'
            end,
        },
    },
    -- #https://www.dpreview.com/forums/threads/gr-iv-hdf-dng-exif-data.4837151/#post-68693164
    [0x009e] = {
        Name = 'HDF', -- (Highlight Diffusion Filter)
        Writable = 'int8u',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x0200] = { -- #5
        Name = 'BlackPoint',
        Writable = 'int16u',
        Count = 4,
    },
    [0x0201] = { -- #5
        Name = 'WhitePoint',
        Writable = 'int16u',
        Count = 4,
    },
    [0x0203] = { -- #JD (not really sure what these mean)
        Name = 'ColorMatrixA', -- (camera RGB to sRGB matrix, *ist D, ref IB)
        Writable = 'int16s',
        Count = 9,
        ValueConv = function(_self, val)
            local a = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = str(tonumber(w) / 8192) end
            return table.concat(a, ' ')
        end,
        ValueConvInv = function(_self, val)
            local a = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do
                local n = tonumber(w)
                a[#a + 1] = str(math.floor(n * 8192 + (n < 0 and -0.5 or 0.5)))
            end
            return table.concat(a, ' ')
        end,
        PrintConv = function(_self, val)
            local a = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = sprintf('%.5f', tonumber(w)) end
            return table.concat(a, ' ')
        end,
        PrintConvInv = function(_self, val) return str(val) end,
    },
    [0x0204] = { -- #JD
        Name = 'ColorMatrixB', -- (camera RGB to Adobe RGB matrix, *ist D, ref IB)
        Writable = 'int16s',
        Count = 9,
        ValueConv = function(_self, val)
            local a = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = str(tonumber(w) / 8192) end
            return table.concat(a, ' ')
        end,
        ValueConvInv = function(_self, val)
            local a = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do
                local n = tonumber(w)
                a[#a + 1] = str(math.floor(n * 8192 + (n < 0 and -0.5 or 0.5)))
            end
            return table.concat(a, ' ')
        end,
        PrintConv = function(_self, val)
            local a = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = sprintf('%.5f', tonumber(w)) end
            return table.concat(a, ' ')
        end,
        PrintConvInv = function(_self, val) return str(val) end,
    },
    [0x0205] = {
        { -- #19
            Name = 'CameraSettings',
            -- size: *istD/*istDs/K100D/K110D=16, K-m/K2000=14, K-7/K-x=19,
            --       K200D/K20D/K-5/645D=20, K-r=21, K10D=22, K-01=25
            Condition = function(_self, _val, _format, count) return count < 25 end, -- (not valid for the K-01)
            SubDirectory = {
                TagTable = 'lexiftool.Pentax.CameraSettings',
                ByteOrder = 'BigEndian',
            },
        },
        {
            Name = 'CameraSettingsUnknown',
            SubDirectory = {
                TagTable = 'lexiftool.Pentax.CameraSettingsUnknown',
                ByteOrder = 'BigEndian',
            },
        },
    },
    [0x0206] = {
        { -- #PH
            Name = 'AEInfo',
            -- size: *istD/*istDs/K100D/K110D=14, K10D/K200D/K20D=16, K-m/K2000=20,
            --        K-7/K-x=24, K-5/K-r/645D=25
            Condition = function(self, _val, _format, count)
                self.AEInfoSize = count
                return count <= 25 and count ~= 21
            end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.AEInfo' },
        },
        {
            Name = 'AEInfo2',
            -- size: K-01=21
            Condition = function(_self, _val, _format, count) return count == 21 end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.AEInfo2' },
        },
        {
            Name = 'AEInfo3',
            -- size: K-30=48, K-1mkII,K-70,KP=64
            Condition = function(_self, _val, _format, count) return count == 48 or count == 64 end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.AEInfo3' },
        },
        {
            Name = 'AEInfoUnknown',
            -- size: Q/Q10=34
            SubDirectory = { TagTable = 'lexiftool.Pentax.AEInfoUnknown' },
        },
    },
    [0x0207] = { -- #PH
        {
            Name = 'LensInfo',
            -- the *ist series (and Samsung GX-1) always use the old format, and all
            -- other models but the K100D, K110D and K100D Super always use the newer
            -- format, and for the K110D/K110D we expect ff or 00 00 at byte 20 if
            -- it is the old format.)
            Condition = function(self, val)
                local m = str(self.Model or '')
                return matches(m, [==[(\*ist|GX-1[LS])]==]) ~= nil or
                      (matches(m, [==[(K100D|K110D)]==]) ~= nil and
                       matches(str(val), [==[(?s)^.{20}(\xff|\0\0)]==]) ~= nil)
            end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.LensInfo' },
        },
        {
            Name = 'LensInfo',
            Condition = function(_self, _val, _format, count)
                return count ~= 90 and count ~= 91 and count ~= 80 and count ~= 128 and count ~= 168
            end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.LensInfo2' },
        },
        {
            Name = 'LensInfo', -- 645D
            Condition = function(_self, _val, _format, count) return count == 90 end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.LensInfo3' },
        },
        {
            Name = 'LensInfo', -- K-r, K-5, K-5II
            Condition = function(_self, _val, _format, count) return count == 91 end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.LensInfo4' },
        },
        {
            Name = 'LensInfo', -- K-01, K-30, K-50, K-500, K-3, K-3II
            Condition = function(_self, _val, _format, count) return count == 80 or count == 128 end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.LensInfo5' },
        }
        -- ($count == 168 - Ricoh GR III)
    },
    [0x0208] = { -- #PH
        {
            Name = 'FlashInfo',
            Condition = function(_self, _val, _format, count) return count == 27 end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.FlashInfo' },
        },
        {
            Name = 'FlashInfoUnknown',
            SubDirectory = { TagTable = 'lexiftool.Pentax.FlashInfoUnknown' },
        },
    },
    [0x0209] = { -- #PH
        Name = 'AEMeteringSegments',
        Format = 'int8u',
        Count = -1,
        Notes = [[
            measurements from each of the 16 AE metering segments for models such as the
            K10D, 77 metering segments for models such as the K-5, and 4050 metering
            segments for the K-3, converted to LV
        ]],
        PrintConv = convertMeteringSegments.PrintConv,
        PrintConvInv = convertMeteringSegments.PrintConvInv,
    },
    [0x020a] = { -- #PH/JD/19
        Name = 'FlashMeteringSegments',
        Format = 'int8u',
        Count = -1,
        PrintConv = convertMeteringSegments.PrintConv,
        PrintConvInv = convertMeteringSegments.PrintConvInv,
    },
    [0x020b] = { -- #PH/JD/19
        Name = 'SlaveFlashMeteringSegments',
        Format = 'int8u',
        Count = -1,
        Notes = 'used in wireless control mode',
        PrintConv = convertMeteringSegments.PrintConv,
        PrintConvInv = convertMeteringSegments.PrintConvInv,
    },
    [0x020d] = { Name = 'WB_RGGBLevelsDaylight', Writable = 'int16u', Count = 4 }, -- #PH
    [0x020e] = { Name = 'WB_RGGBLevelsShade', Writable = 'int16u', Count = 4 }, -- #PH
    [0x020f] = { Name = 'WB_RGGBLevelsCloudy', Writable = 'int16u', Count = 4 }, -- #PH
    [0x0210] = { Name = 'WB_RGGBLevelsTungsten', Writable = 'int16u', Count = 4 }, -- #PH
    [0x0211] = { Name = 'WB_RGGBLevelsFluorescentD', Writable = 'int16u', Count = 4 }, -- #PH
    [0x0212] = { Name = 'WB_RGGBLevelsFluorescentN', Writable = 'int16u', Count = 4 }, -- #PH
    [0x0213] = { Name = 'WB_RGGBLevelsFluorescentW', Writable = 'int16u', Count = 4 }, -- #PH
    [0x0214] = { Name = 'WB_RGGBLevelsFlash', Writable = 'int16u', Count = 4 }, -- #PH
    [0x0215] = { -- #PH
        Name = 'CameraInfo',
        Format = 'undef', -- (written as int32u)
        SubDirectory = { TagTable = 'lexiftool.Pentax.CameraInfo' },
    },
    [0x0216] = { -- #PH
        Name = 'BatteryInfo',
        SubDirectory = {
            TagTable = 'lexiftool.Pentax.BatteryInfo',
            ByteOrder = 'BigEndian', -- have seen makernotes changed to little-endian in DNG!
        },
    },
    [0x021b] = { -- #19
        Name = 'SaturationInfo',
        Flags = { 'Unknown', 'Binary' },
        Writable = 0,
        Notes = 'only in PEF and DNG images',
        -- K10D values with various Saturation settings (ref 19):
        -- Very Low: 000000022820f9a0fe4000802660f92002e0fee01e402c40f880fb40ffc02b20f52002e0fe401ee0
        -- Low:      000000022ae0f700fe20ff402840f88001e0fcc021602f60f560fb40fe602d20f48001c0fbc02280
        -- Med Low:  000000022dc0f420fe20fe002a20f7e000c0fa8024c032c0f220fb20fce02f60f3c000a0f9202640
        -- Normal:   000000023120f0e0fe00fc802c40f740ffa0f7e028803660ee80fb20fb4031c0f300ff60f6202a80
        -- Med High: 0000000234e0ed40fde0fae02ea0f680fe60f5002ca03a80ea80fb00f9603480f220fe00f2e02f20
        -- High:     0000000238c0e960fde0f9203140f5a0fce0f1e031403f00e600fb00f7803760f120fc60ef403460
        -- Very High:000000023d20e520fdc0f7203420f4c0fb60ee6036404400e120fae0f5403aa0f020fac0eb403a00
    },
    [0x021c] = { -- #IB
        Name = 'ColorMatrixA2',
        Format = 'int16s',
        Writable = 'undef',
        Count = 9,
    },
    [0x021d] = { -- #IB
        Name = 'ColorMatrixB2',
        Format = 'int16s',
        Writable = 'undef',
        Count = 9,
    },
    [0x021f] = { -- #JD
        Name = 'AFInfo',
        SubDirectory = {
            ByteOrder = 'BigEndian',
            TagTable = 'lexiftool.Pentax.AFInfo',
        },
    },
    [0x0220] = { -- #6
        Name = 'HuffmanTable',
        Flags = { 'Unknown', 'Binary' },
        Writable = 0,
        Notes = 'found in K10D, K20D and K2000 PEF images',
    },
    [0x0221] = { -- #28
        Name = 'KelvinWB',
        SubDirectory = { TagTable = 'lexiftool.Pentax.KelvinWB' },
    },
    [0x0222] = { -- #PH
        Name = 'ColorInfo',
        SubDirectory = { TagTable = 'lexiftool.Pentax.ColorInfo' },
    },
    [0x0224] = { -- #19
        Name = 'EVStepInfo',
        Drop = 200, -- drop if larger than 200 bytes (40 kB in Pentax Q and Q10)
        SubDirectory = { TagTable = 'lexiftool.Pentax.EVStepInfo' },
    },
    [0x0226] = { -- #PH
        Name = 'ShotInfo', -- (may want to change this later when more is decoded)
        SubDirectory = { TagTable = 'lexiftool.Pentax.ShotInfo' },
    },
    [0x0227] = { -- #PH
        Name = 'FacePos',
        Condition = function(self) return ExifTool.perlTruthy(self.FacesDetected) end, -- ignore if no faces to decode
        SubDirectory = { TagTable = 'lexiftool.Pentax.FacePos' },
    },
    [0x0228] = { -- #PH
        Name = 'FaceSize',
        Condition = function(self) return ExifTool.perlTruthy(self.FacesDetected) end, -- ignore if no faces to decode
        SubDirectory = { TagTable = 'lexiftool.Pentax.FaceSize' },
    },
    [0x0229] = { -- #PH (verified) (K-m, K-x, K-7)
        Name = 'SerialNumber',
        Writable = 'string',
        Notes = 'left blank by some cameras',
    },
    [0x022a] = {
        { -- #PH (RICOH models (GR III))
            Name = 'FilterInfo',
            Condition = function(self) return matches(str(self.Make or ''), [==[^RICOH]==]) ~= nil end,
            SubDirectory = {
                TagTable = 'lexiftool.Pentax.FilterInfo',
                ByteOrder = 'LittleEndian',
            },
        },
        { -- #PH (K-5)
            Name = 'FilterInfo',
            SubDirectory = {
                TagTable = 'lexiftool.Pentax.FilterInfo',
                ByteOrder = 'BigEndian',
            },
        },
    },
    [0x022b] = {
        {
            Name = 'LevelInfoK3III',
            Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.LevelInfoK3III' },
        },
        { -- #PH (K-5)
            Name = 'LevelInfo',
            SubDirectory = { TagTable = 'lexiftool.Pentax.LevelInfo' },
        },
    },
    [0x022d] = { -- #28
        Name = 'WBLevels',
        Condition = function(_self, _val, _format, count) return count == 100 end, -- (just to be safe, but no other counts observed)
        SubDirectory = { TagTable = 'lexiftool.Pentax.WBLevels' },
    },
    [0x022e] = { -- #PH (K-5 AVI videos)
        Name = 'Artist',
        Groups = { [2] = 'Author' },
        Writable = 'string',
    },
    [0x022f] = { -- #PH (K-5 AVI videos)
        Name = 'Copyright',
        Groups = { [2] = 'Author' },
        Writable = 'string',
    },
    [0x0230] = { -- #PH (K-x AVI videos) (and K-70/Q-S1 MOV videos, ref 31)
        Name = 'FirmwareVersion',
        Notes = 'only in videos',
        Writable = 'string',
        -- this tag only exists in AVI/MOV videos, and for the K-x the value of
        -- this tag is "K-x Ver 1.00", which is the same as the EXIF Software
        -- tag.  I used a different tag name for this because Pentax uses the
        -- AVI Software tag for a different string, "PENTAX K-x".
    },
    [0x0231] = { -- #PH (K-5)
        Name = 'ContrastDetectAFArea',
        Writable = 'int16u',
        Count = 4,
        Notes = [[
            AF area of the most recent contrast-detect focus operation. Coordinates
            are left, top, width and height in a 720x480 frame, with Y downwards
        ]],
    },
    [0x0235] = { -- #PH (K-5)
        Name = 'CrossProcessParams',
        -- (it would be interesting to know exactly what these mean)
        Writable = 'undef',
        Format = 'int8u',
        Count = 10,
    },
    [0x0238] = { -- #KarstenGieselmann
        Name = 'CAFPointInfo',
        SubDirectory = { TagTable = 'lexiftool.Pentax.CAFPointInfo' },
    },
    [0x0239] = { -- #PH
        Name = 'LensInfoQ',
        SubDirectory = { TagTable = 'lexiftool.Pentax.LensInfoQ' },
    },
    [0x023f] = { -- #31 (K-70 MOV videos)
        Name = 'Model',
        Description = 'Camera Model Name',
        Writable = 'string',
    },
    [0x0243] = { -- #PH
        Name = 'PixelShiftInfo',
        SubDirectory = { TagTable = 'lexiftool.Pentax.PixelShiftInfo' },
    },
    [0x0245] = { -- #29
        Name = 'AFPointInfo',
        SubDirectory = { TagTable = 'lexiftool.Pentax.AFPointInfo' },
    },
    [0x03fe] = { -- #PH
        Name = 'DataDump',
        Writable = 0,
        PrintConv = '$val',
    },
    [0x03ff] = { -- #PH
        {
            Name = 'TempInfo',
            Condition = function(self) return matches(self.Model, [[K-(01|3|30|5|50|500)\b]]) ~= nil end,
            SubDirectory = { TagTable = 'lexiftool.Pentax.TempInfo' },
        },
        {
            Name = 'UnknownInfo',
            SubDirectory = { TagTable = 'lexiftool.Pentax.UnknownInfo' },
        },
    },
    [0x0402] = { -- #5
        Name = 'ToneCurve',
        PrintConv = '$val',
    },
    [0x0403] = { -- #5
        Name = 'ToneCurves',
        PrintConv = '$val',
    },
    [0x0405] = { -- #PH - undef[24200] (K-5 PEF/DNG only), undef[28672] (Q DNG)
        Name = 'UnknownBlock',
        Writable = 'undef',
        Notes = 'large unknown data block in PEF/DNG images but not JPG images',
        Flags = { 'Unknown', 'Binary', 'Drop' },
    },
    [0x040b] = {
        Name = 'FaceInfoK3III',
        -- undef[1640] (actually int32u[410], K3III)
        SubDirectory = { TagTable = 'lexiftool.Pentax.FaceInfoK3III' },
    },
    [0x040c] = {
        Name = 'AFInfoK3III',
        SubDirectory = { TagTable = 'lexiftool.Pentax.AFInfoK3III' },
    },
    [0x0e00] = {
        Name = 'PrintIM',
        Description = 'Print Image Matching',
        Writable = 0,
        SubDirectory = { TagTable = 'lexiftool.PrintIM.Main' },
    },
}

Pentax.TempInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = [[
        A number of additional temperature readings are extracted from this 256-byte
        binary-data block in images from models such as the K-01, K-3, K-5, K-50 and
        K-500.  It is currently not known where the corresponding temperature
        sensors are located in the camera.
    ]],
    [0x0a] = { -- #KG
        Name = 'ShotNumber',
        Condition = function(self) return matches(self.Model, [[K-3 Mark III]]) ~= nil end,
        -- The exact same method to detect this tag with a similar set of files
        -- does not reveal anything for K-1. Is this only available for K-3-III ?
        -- Internal representation starts at 0 for the 1st shot
        ValueConv = function(_self, val) return val + 1 end,
    },
    -- (it would be nice to know where these temperature sensors are located,
    --  but since according to the manual the Slow Shutter Speed NR Auto mode
    --  is based on "internal temperature", my guess is that there must be
    --  at least one on the sensor itself.  These temperatures seem to rise
    --  more quickly than CameraTemperature when shooting video.)
    [0x0c] = {
        Name = 'SensorTemperature', -- #forum6677 (was CameraTemperature2)
        Condition = function(self) return matches(self.Model, [[K-3 Mark III]]) == nil end, -- (and maybe others?)
        Format = 'int16s',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
        PrintConv = function(_self, val) return sprintf('%.1f C', val) end,
        PrintConvInv = function(_self, val) return (subst(val, [[(?i) ?c$]], '')) end,
    },
    [0x0e] = {
        Name = 'SensorTemperature2', -- #forum6677 (was CameraTemperature3)
        Condition = function(self) return matches(self.Model, [[K-3 Mark III]]) == nil end, -- (and maybe others?)
        Format = 'int16s',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
        PrintConv = function(_self, val) return sprintf('%.1f C', val) end,
        PrintConvInv = function(_self, val) return (subst(val, [[(?i) ?c$]], '')) end,
    },
    [0x14] = {
        Name = 'CameraTemperature4',
        Condition = function(self) return matches(self.Model, [[K-5\b]]) ~= nil end,
        Format = 'int16s',
        PrintConv = function(_self, val) return perl.str(val) .. ' C' end,
        PrintConvInv = function(_self, val) return (subst(val, [[(?i) ?c$]], '')) end,
    },
    [0x16] = { -- usually the same as CameraTemperature4, but not always
        Name = 'CameraTemperature5',
        Condition = function(self) return matches(self.Model, [[K-5\b]]) ~= nil end,
        Format = 'int16s',
        PrintConv = function(_self, val) return perl.str(val) .. ' C' end,
        PrintConvInv = function(_self, val) return (subst(val, [[(?i) ?c$]], '')) end,
    },
    -- 0x18,0x1a,0x1c,0x1e = int16u[4] BlackPoint - PH
    [0x2a] = {
        Name = 'SensorTemperature',
        Condition = function(self) return matches(self.Model, [[K-3 Mark III]]) ~= nil end,
        Format = 'int16s',
        ValueConv = function(_self, val) return val / 10 end,
        ValueConvInv = function(_self, val) return val * 10 end,
        PrintConv = function(_self, val) return sprintf('%.1f C', val) end,
        PrintConvInv = function(_self, val) return (subst(val, [[(?i) ?c$]], '')) end,
    },
}

-- currently unknown info
Pentax.UnknownInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    -- K10D: first 8 bytes seem to be short integers which change with ISO (value
    -- is usually close to ISO/100) possibly smoothing or gain parameters? - PH
    -- byte 0-1 - Higher for high color temperatures (red boost or red noise suppression?)
    -- byte 6-7 - Higher for low color temperatures (blue boost or blue noise suppression?)
    -- also changing are bytes 10,11,14,15
}

-- unknown camera settings (Q, Q10)
Pentax.CameraSettingsUnknown = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
}

-- auto-exposure information for the K-01 (ref PH)
Pentax.AEInfo2 = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'Auto-exposure information for the K-01.',
    -- instead of /8, should these be PentaxEv(), as in CameraSettings? - PH
    [2] = {
        Name = 'AEExposureTime',
        Notes = 'val = 24 * 2**((32-raw)/8)',
        ValueConv = function(_self, val) return 24 * math.exp(-(val - 32) * math.log(2) / 8) end,
        ValueConvInv = function(_self, val) return -math.log(val / 24) * 8 / math.log(2) + 32 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return Exif.ConvertFraction(val) end,
    },
    [3] = {
        Name = 'AEAperture',
        Notes = 'val = 2**((raw-68)/16)',
        ValueConv = function(_self, val) return math.exp((val - 68) * math.log(2) / 16) end,
        ValueConvInv = function(_self, val) return math.log(val) * 16 / math.log(2) + 68 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [4] = {
        Name = 'AE_ISO',
        Notes = 'val = 100 * 2**((raw-32)/8)',
        ValueConv = function(_self, val) return 100 * math.exp((val - 32) * math.log(2) / 8) end,
        ValueConvInv = function(_self, val) return math.log(val / 100) * 8 / math.log(2) + 32 end,
        PrintConv = function(_self, val) return math.floor(val + 0.5) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [5] = {
        Name = 'AEXv',
        -- this is the negative of exposure compensation, not including bracketing
        Notes = 'val = (raw-64)/8',
        ValueConv = function(_self, val) return (val - 64) / 8 end,
        ValueConvInv = function(_self, val) return val * 8 + 64 end,
    },
    [6] = {
        Name = 'AEBXv',
        -- this is the negative of auto exposure bracketing compensation
        Format = 'int8s',
        Notes = 'val = raw / 8',
        ValueConv = function(_self, val) return val / 8 end,
        ValueConvInv = function(_self, val) return val * 8 end,
    },
    [8] = {
        Name = 'AEError',
        Format = 'int8s',
        -- this is usually zero except in M exposure mode, but it can be non-zero
        -- in other modes (eg. if you hit an aperture limit in Tv mode)
        ValueConv = function(_self, val) return -(val - 64) / 8 end, -- (negate to make overexposed positive)
        ValueConvInv = function(_self, val) return -val * 8 + 64 end,
    },
    [11] = {
        Name = 'AEApertureSteps',
        Notes = [[
            number of steps the aperture has been stopped down from wide open.  There
            are roughly 8 steps per F-stop, but it varies slightly by lens
        ]],
        PrintConv = function(_self, val) return val == 255 and 'n/a' or val end,
        PrintConvInv = function(_self, val) return val == 'n/a' and 255 or val end,
    },
    [15] = {
        Name = 'SceneMode',
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'Off',
            [1] = 'HDR',
            [4] = 'Auto PICT',
            [5] = 'Portrait',
            [6] = 'Landscape',
            [7] = 'Macro',
            [8] = 'Sport',
            [9] = 'Night Scene Portrait',
            [10] = 'No Flash',
            [11] = 'Night Scene',
            [12] = 'Surf & Snow',
            [14] = 'Sunset',
            [15] = 'Kids',
            [16] = 'Pet',
            [17] = 'Candlelight',
            [18] = 'Museum',
            [20] = 'Food',
            [21] = 'Stage Lighting',
            [22] = 'Night Snap',
            [25] = 'Night Scene HDR',
            [26] = 'Blue Sky',
            [27] = 'Forest',
            [29] = 'Backlight Silhouette',
        },
    },
    [16] = {
        Name = 'AEMaxAperture',
        Notes = 'val = 2**((raw-68)/16)',
        ValueConv = function(_self, val) return math.exp((val - 68) * math.log(2) / 16) end,
        ValueConvInv = function(_self, val) return math.log(val) * 16 / math.log(2) + 68 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [17] = {
        Name = 'AEMaxAperture2',
        Notes = 'val = 2**((raw-68)/16)',
        ValueConv = function(_self, val) return math.exp((val - 68) * math.log(2) / 16) end,
        ValueConvInv = function(_self, val) return math.log(val) * 16 / math.log(2) + 68 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [18] = {
        Name = 'AEMinAperture',
        Notes = 'val = 2**((raw-68)/16)',
        ValueConv = function(_self, val) return math.exp((val - 68) * math.log(2) / 16) end,
        ValueConvInv = function(_self, val) return math.log(val) * 16 / math.log(2) + 68 end,
        PrintConv = function(_self, val) return sprintf('%.0f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [19] = {
        Name = 'AEMinExposureTime',
        Notes = 'val = 24 * 2**((32-raw)/8)',
        ValueConv = function(_self, val) return 24 * math.exp(-(val - 32) * math.log(2) / 8) end,
        ValueConvInv = function(_self, val) return -math.log(val / 24) * 8 / math.log(2) + 32 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return Exif.ConvertFraction(val) end,
    },
}

-- auto-exposure information for the K-30 (ref PH)
Pentax.AEInfo3 = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = [[
        Auto-exposure information for the K-1mkII, K-3, K-30, K-50, K-70, K-500 and
        KP.
    ]],
    -- instead of /8, should these be PentaxEv(), as in CameraSettings? - PH
    [16] = {
        Name = 'AEExposureTime',
        Notes = 'val = 24 * 2**((32-raw)/8)',
        ValueConv = function(_self, val) return 24 * math.exp(-(val - 32) * math.log(2) / 8) end,
        ValueConvInv = function(_self, val) return -math.log(val / 24) * 8 / math.log(2) + 32 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return Exif.ConvertFraction(val) end,
    },
    [17] = {
        Name = 'AEAperture',
        Notes = 'val = 2**((raw-68)/16)',
        ValueConv = function(_self, val) return math.exp((val - 68) * math.log(2) / 16) end,
        ValueConvInv = function(_self, val) return math.log(val) * 16 / math.log(2) + 68 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [18] = {
        Name = 'AE_ISO',
        Notes = 'val = 100 * 2**((raw-32)/8)',
        ValueConv = function(_self, val) return 100 * math.exp((val - 32) * math.log(2) / 8) end,
        ValueConvInv = function(_self, val) return math.log(val / 100) * 8 / math.log(2) + 32 end,
        PrintConv = function(_self, val) return math.floor(val + 0.5) end,
        PrintConvInv = function(_self, val) return val end,
    },
    -- 23 - bit 0 is related to LiveView, but it isn't reliable
    [28] = {
        Name = 'AEMaxAperture',
        Notes = 'val = 2**((raw-68)/16)',
        ValueConv = function(_self, val) return math.exp((val - 68) * math.log(2) / 16) end,
        ValueConvInv = function(_self, val) return math.log(val) * 16 / math.log(2) + 68 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [29] = {
        Name = 'AEMaxAperture2',
        Notes = 'val = 2**((raw-68)/16)',
        ValueConv = function(_self, val) return math.exp((val - 68) * math.log(2) / 16) end,
        ValueConvInv = function(_self, val) return math.log(val) * 16 / math.log(2) + 68 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [30] = {
        Name = 'AEMinAperture',
        Notes = 'val = 2**((raw-68)/16)',
        ValueConv = function(_self, val) return math.exp((val - 68) * math.log(2) / 16) end,
        ValueConvInv = function(_self, val) return math.log(val) * 16 / math.log(2) + 68 end,
        PrintConv = function(_self, val) return sprintf('%.0f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [31] = {
        Name = 'AEMinExposureTime',
        Notes = 'val = 24 * 2**((32-raw)/8)',
        ValueConv = function(_self, val) return 24 * math.exp(-(val - 32) * math.log(2) / 8) end,
        ValueConvInv = function(_self, val) return -math.log(val / 24) * 8 / math.log(2) + 32 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return Exif.ConvertFraction(val) end,
    },
}

-- unknown auto-exposure information (Q, Q10)
Pentax.AEInfoUnknown = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
}

-- lens type
Pentax.LensRec = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = [[
        This record stores the LensType, plus one or two unknown bytes for some
        models.
    ]],
    [0] = {
        Name = 'LensType',
        Format = 'int8u[2]',
        Priority = 0,
        ValueConvInv = function(_self, val) return (subst(val, [[\.\d+$]], '')) end,
        PrintConv = pentaxLensTypes,
        SeparateTable = 1,
        PrintInt = 1,
    },
    [3] = { -- #PH
        Name = 'ExtenderStatus',
        Notes = 'not valid if a non-AF lens is used',
        PrintConv = { [0] = 'Not attached', [1] = 'Attached' },
    },
}

Pentax.SRInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'Shake reduction information.',
    [0] = {
        Name = 'SRResult',
        PrintConv = { -- #PH/JD
            [0] = 'Not stabilized',
            BITMASK = {
                [0] = 'Stabilized',
                [6] = 'Not ready',
            },
        },
    },
    [1] = {
        Name = 'ShakeReduction',
        PrintConv = {
            [0] = 'Off', [1] = 'On', [4] = 'Off (4)', [5] = 'On but Disabled',
            [6] = 'On (Video)', [7] = 'On (7)', [15] = 'On (15)',
            [39] = 'On (mode 2)', [135] = 'On (135)', [167] = 'On (mode 1)',
        },
    },
    [2] = {
        Name = 'SRHalfPressTime',
        Notes = [[
            time from when the shutter button was half pressed to when the shutter was
            released, including time for focusing.  Not valid for some models
        ]],
        ValueConv = function(_self, val) return val / 60 end,
        ValueConvInv = function(_self, val)
            local v = val * 60
            if v < 255 then return perl.int(v + 0.5) end
            return 255
        end,
        PrintConv = function(_self, val)
            local s = sprintf('%.2f s', val)
            if val > 254.5 / 60 then s = s .. ' or longer' end
            return s
        end,
        PrintConvInv = function(_self, val) return (perl.tr(val, '0-9.', '', 'dc')) end,
    },
    [3] = { -- #JD
        Name = 'SRFocalLength',
        ValueConv = function(_self, val) return (val & 0x01) ~= 0 and val * 4 or val / 2 end,
        ValueConvInv = function(_self, val)
            if perl.num(val) <= 127 then return perl.int(val) * 2 end
            return perl.int(val / 4) | 0x01
        end,
        PrintConv = function(self, val) return self.NumStr(val) .. ' mm' end,
        PrintConvInv = function(_self, val) return (subst(val, [[\s*mm]], '')) end,
    },
}

-- shake reduction information for the K-3 (ref PH)
Pentax.SRInfo2 = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'Shake reduction information for the K-3.',
    [0] = {
        Name = 'SRResult',
        Unknown = 1,
        PrintConv = { BITMASK = {
            -- Bit 0 - have seen this set in a few Pentax samples - PH
            -- Bit 6 - usually set when SR is Off, and occasionally when On - PH
            -- Bit 7 - set when AA simulation is on - PH
        } },
    },
    [1] = {
        Name = 'ShakeReduction',
        PrintConv = { -- #forum5425
            [0] = 'Off', -- (NC for K-3)
            [1] = 'On', -- (NC for K-3)
            [4] = 'Off (AA simulation off)',
            [5] = 'On but Disabled', -- (NC for K-3)
            [6] = 'On (Video)', -- (NC for K-3)
            [7] = 'On (AA simulation off)',
            [8] = 'Off (AA simulation type 1) (8)', -- #forum8362 (K-70)
            [12] = 'Off (AA simulation type 1)', -- (AA linear motion)
            [15] = 'On (AA simulation type 1)', -- (AA linear motion)
            [16] = 'Off (AA simulation type 2) (16)', -- #forum8362 (K-70)
            [20] = 'Off (AA simulation type 2)', -- (AA circular motion)
            [23] = 'On (AA simulation type 2)', -- (AA circular motion)
        },
    },
}

-- face detection information (ref PH, K-5)
Pentax.FaceInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    DATAMEMBER = { 0 },
    [0] = {
        Name = 'FacesDetected',
        RawConv = function(self, val) self.FacesDetected = val; return val end,
    },
    [2] = {
        Name = 'FacePosition',
        Notes = [[
            X/Y coordinates of the center of the main face in percent of frame size,
            with positive Y downwards
        ]],
        Format = 'int8u[2]',
    },
}

-- automatic white balance settings (ref PH, K-5)
Pentax.AWBInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    -- 0 - always 1?
    -- (data ends here for the K20D, K200D, K-x and K-7)
    [0] = {
        Name = 'WhiteBalanceAutoAdjustment',
        PrintConv = {
            [0] = 'Off',
            [1] = 'On',
        },
    },
    [1] = { -- (exists only for K-5)
        Name = 'TungstenAWB',
        PrintConv = {
            [0] = 'Subtle Correction',
            [1] = 'Strong Correction',
        },
    },
}

-- world time settings (ref PH, K-5)
Pentax.TimeInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Time' },
    [0.1] = {
        Name = 'WorldTimeLocation',
        Mask = 0x01,
        PrintConv = {
            [0] = 'Hometown',
            [1] = 'Destination',
        },
    },
    [0.2] = {
        Name = 'HometownDST',
        Mask = 0x02,
        PrintConv = noYes,
    },
    [0.3] = {
        Name = 'DestinationDST',
        Mask = 0x04,
        PrintConv = noYes,
    },
    [2] = {
        Name = 'HometownCity',
        SeparateTable = 'City',
        PrintConv = pentaxCities,
    },
    [3] = {
        Name = 'DestinationCity',
        SeparateTable = 'City',
        PrintConv = pentaxCities,
    },
}

-- lens distortion correction (ref PH, K-5)
Pentax.LensCorr = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    [0] = {
        Name = 'DistortionCorrection',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [1] = {
        Name = 'ChromaticAberrationCorrection',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [2] = {
        Name = 'PeripheralIlluminationCorr',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [3] = {
        Name = 'DiffractionCorrection',
        PrintConv = { [0] = 'Off', [16] = 'On' },
    },
}

-- camera settings (ref 19)
Pentax.CameraSettings = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    PRIORITY = 0,
    NOTES = 'Camera settings information written by Pentax DSLR cameras.',
    [0] = {
        Name = 'PictureMode2',
        PrintConv = {
            [0] = 'Scene Mode', [1] = 'Auto PICT', [2] = 'Program AE',
            [3] = 'Green Mode', [4] = 'Shutter Speed Priority', [5] = 'Aperture Priority',
            [6] = 'Program Tv Shift', [7] = 'Program Av Shift', [8] = 'Manual',
            [9] = 'Bulb', [10] = 'Aperture Priority, Off-Auto-Aperture',
            [11] = 'Manual, Off-Auto-Aperture', [12] = 'Bulb, Off-Auto-Aperture',
            [13] = 'Shutter & Aperture Priority AE', [15] = 'Sensitivity Priority AE',
            [16] = 'Flash X-Sync Speed AE',
        },
    },
    [1.1] = {
        Name = 'ProgramLine',
        Mask = 0x03,
        PrintConv = { [0] = 'Normal', [1] = 'Hi Speed', [2] = 'Depth', [3] = 'MTF' },
    },
    [1.2] = {
        Name = 'EVSteps',
        Mask = 0x20,
        PrintConv = { [0] = '1/2 EV Steps', [1] = '1/3 EV Steps' },
    },
    [1.3] = {
        Name = 'E-DialInProgram',
        Mask = 0x40,
        PrintConv = { [0] = 'Tv or Av', [1] = 'P Shift' },
    },
    [1.4] = {
        Name = 'ApertureRingUse',
        Mask = 0x80,
        PrintConv = { [0] = 'Prohibited', [1] = 'Permitted' },
    },
    [2] = {
        Name = 'FlashOptions',
        Notes = 'the camera flash options settings, set even if the flash is off',
        Mask = 0xf0,
        PrintConv = {
            [0] = 'Normal', [1] = 'Red-eye reduction', [2] = 'Auto',
            [3] = 'Auto, Red-eye reduction', [5] = 'Wireless (Master)',
            [6] = 'Wireless (Control)', [8] = 'Slow-sync',
            [9] = 'Slow-sync, Red-eye reduction', [10] = 'Trailing-curtain Sync',
        },
    },
    [2.1] = {
        Name = 'MeteringMode2',
        Mask = 0x0f,
        Notes = 'may not be valid for some models, eg. *ist D',
        PrintConv = {
            [0] = 'Multi-segment',
            BITMASK = { [0] = 'Center-weighted average', [1] = 'Spot' },
        },
    },
    [3] = {
        Name = 'AFPointMode',
        Mask = 0xf0,
        PrintConv = {
            [0] = 'Auto',
            BITMASK = { [0] = 'Select', [1] = 'Fixed Center' },
        },
    },
    [3.1] = {
        Name = 'FocusMode2',
        Mask = 0x0f,
        PrintConv = { [0] = 'Manual', [1] = 'AF-S', [2] = 'AF-C', [3] = 'AF-A' },
    },
    [4] = {
        Name = 'AFPointSelected2',
        Format = 'int16u',
        PrintConv = {
            [0] = 'Auto',
            BITMASK = {
                [0] = 'Upper-left', [1] = 'Top', [2] = 'Upper-right', [3] = 'Left',
                [4] = 'Mid-left', [5] = 'Center', [6] = 'Mid-right', [7] = 'Right',
                [8] = 'Lower-left', [9] = 'Bottom', [10] = 'Lower-right',
            },
        },
    },
    [6] = {
        Name = 'ISOFloor', -- #PH
        ValueConv = function(_self, val) return math.floor(100 * math.exp(PentaxEv(val - 32) * math.log(2)) + 0.5) end,
        ValueConvInv = function(_self, val) return PentaxEvInv(perl.log(val / 100) / math.log(2)) + 32 end,
    },
    [7] = {
        Name = 'DriveMode2',
        PrintConv = {
            [0] = 'Single-frame',
            BITMASK = {
                [0] = 'Continuous', [1] = 'Continuous (Lo)', [2] = 'Self-timer (12 s)',
                [3] = 'Self-timer (2 s)', [4] = 'Remote Control (3 s delay)',
                [5] = 'Remote Control', [6] = 'Exposure Bracket', [7] = 'Multiple Exposure',
            },
        },
    },
    [8] = {
        Name = 'ExposureBracketStepSize',
        PrintConv = {
            [3] = '0.3', [4] = '0.5', [5] = '0.7', [8] = '1.0', [11] = '1.3',
            [12] = '1.5', [13] = '1.7', [16] = '2.0',
        },
    },
    [9] = { -- #PH/19
        Name = 'BracketShotNumber',
        PrintHex = 1,
        PrintConv = {
            [0] = 'n/a', [0x02] = '1 of 2', [0x12] = '2 of 2', [0x03] = '1 of 3',
            [0x13] = '2 of 3', [0x23] = '3 of 3', [0x05] = '1 of 5', [0x15] = '2 of 5',
            [0x25] = '3 of 5', [0x35] = '4 of 5', [0x45] = '5 of 5',
        },
    },
    [10] = {
        Name = 'WhiteBalanceSet',
        Mask = 0xf0,
        PrintConv = {
            [0] = 'Auto', [1] = 'Daylight', [2] = 'Shade', [3] = 'Cloudy',
            [4] = 'Daylight Fluorescent', [5] = 'Day White Fluorescent',
            [6] = 'White Fluorescent', [7] = 'Tungsten', [8] = 'Flash', [9] = 'Manual',
            [12] = 'Set Color Temperature 1', [13] = 'Set Color Temperature 2',
            [14] = 'Set Color Temperature 3',
        },
    },
    [10.1] = {
        Name = 'MultipleExposureSet',
        Mask = 0x0f,
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [13] = {
        Name = 'RawAndJpgRecording',
        Condition = function(self) return matches(self.Model, [[(K10D|GX10)\b]]) ~= nil end,
        Notes = 'K10D only',
        PrintHex = 1,
        PrintConv = {
            [0x01] = 'JPEG (Best)', [0x04] = 'RAW (PEF, Best)', [0x05] = 'RAW+JPEG (PEF, Best)',
            [0x08] = 'RAW (DNG, Best)', [0x09] = 'RAW+JPEG (DNG, Best)',
            [0x21] = 'JPEG (Better)', [0x24] = 'RAW (PEF, Better)',
            [0x25] = 'RAW+JPEG (PEF, Better)', [0x28] = 'RAW (DNG, Better)',
            [0x29] = 'RAW+JPEG (DNG, Better)', [0x41] = 'JPEG (Good)',
            [0x44] = 'RAW (PEF, Good)', [0x45] = 'RAW+JPEG (PEF, Good)',
            [0x48] = 'RAW (DNG, Good)', [0x49] = 'RAW+JPEG (DNG, Good)',
        },
    },
    [14.1] = { -- #PH
        Name = 'JpgRecordedPixels',
        Condition = function(self) return matches(self.Model, [[(K10D|GX10)\b]]) ~= nil end,
        Notes = 'K10D only',
        Mask = 0x03,
        PrintConv = { [0] = '10 MP', [1] = '6 MP', [2] = '2 MP' },
    },
    [14.2] = { -- #PH (K-5)
        Name = 'LinkAEToAFPoint',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-5\b]==]) ~= nil end,
        Notes = 'K-5 only',
        Mask = 0x01,
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [14.3] = { -- #PH (K-5)
        Name = 'SensitivitySteps',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-5\b]==]) ~= nil end,
        Notes = 'K-5 only',
        Mask = 0x02,
        PrintConv = {
            [0] = '1 EV Steps',
            [1] = 'As EV Steps',
        },
    },
    [14.4] = { -- #PH (K-5)
        Name = 'ISOAuto',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-5\b]==]) ~= nil end,
        Notes = 'K-5 only',
        Mask = 0x04,
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    -- 14.5 Mask 0x80 - changes for K-5
    [16] = {
        Name = 'FlashOptions2',
        Condition = function(self) return matches(self.Model, [[(K10D|GX10)\b]]) ~= nil end,
        Notes = 'K10D only; set even if the flash is off',
        Mask = 0xf0,
        PrintConv = {
            [0] = 'Normal', [1] = 'Red-eye reduction', [2] = 'Auto',
            [3] = 'Auto, Red-eye reduction', [5] = 'Wireless (Master)',
            [6] = 'Wireless (Control)', [8] = 'Slow-sync',
            [9] = 'Slow-sync, Red-eye reduction', [10] = 'Trailing-curtain Sync',
        },
    },
    [16.1] = {
        Name = 'MeteringMode3',
        Condition = function(self) return matches(self.Model, [[(K10D|GX10)\b]]) ~= nil end,
        Notes = 'K10D only',
        Mask = 0x0f,
        PrintConv = {
            [0] = 'Multi-segment',
            BITMASK = { [0] = 'Center-weighted average', [1] = 'Spot' },
        },
    },
    [17.1] = {
        Name = 'SRActive',
        Condition = function(self) return matches(self.Model, [[(K10D|GX10)\b]]) ~= nil end,
        Notes = [[
            K10D only; SR is active only when ShakeReduction is On, DriveMode is not
            Remote or Self-timer, and Internal/ExternalFlashMode is not "On, Wireless"
        ]],
        Mask = 0x80,
        PrintConv = noYes,
    },
    [17.2] = {
        Name = 'Rotation',
        Condition = function(self) return matches(self.Model, [[(K10D|GX10)\b]]) ~= nil end,
        Notes = 'K10D only',
        Mask = 0x60,
        PrintConv = {
            [0] = 'Horizontal (normal)', [1] = 'Rotate 180', [2] = 'Rotate 90 CW',
            [3] = 'Rotate 270 CW',
        },
    },
    [17.3] = {
        Name = 'ISOSetting',
        Condition = function(self) return matches(self.Model, [[(K10D|GX10)\b]]) ~= nil end,
        Notes = 'K10D only',
        Mask = 0x04,
        PrintConv = { [0] = 'Manual', [1] = 'Auto' },
    },
    [17.4] = {
        Name = 'SensitivitySteps',
        Condition = function(self) return matches(self.Model, [[(K10D|GX10)\b]]) ~= nil end,
        Notes = 'K10D only',
        Mask = 0x02,
        PrintConv = { [0] = '1 EV Steps', [1] = 'As EV Steps' },
    },
    [18] = {
        Name = 'TvExposureTimeSetting',
        Condition = function(self) return matches(self.Model, [[(K10D|GX10)\b]]) ~= nil end,
        Notes = 'K10D only',
        ValueConv = function(_self, val) return math.exp(-PentaxEv(val - 68) * math.log(2)) end,
        ValueConvInv = function(_self, val) return PentaxEvInv(-perl.log(val) / math.log(2)) + 68 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return Exif.ConvertFraction(val) end,
    },
    [19] = {
        Name = 'AvApertureSetting',
        Condition = function(self) return matches(self.Model, [[(K10D|GX10)\b]]) ~= nil end,
        Notes = 'K10D only',
        ValueConv = function(_self, val) return math.exp(PentaxEv(val - 68) * math.log(2) / 2) end,
        ValueConvInv = function(_self, val) return PentaxEvInv(perl.log(val) * 2 / math.log(2)) + 68 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [20] = { -- #PH
        Name = 'SvISOSetting',
        Condition = function(self) return matches(self.Model, [[(K10D|GX10)\b]]) ~= nil end,
        Notes = 'K10D only',
        ValueConv = function(_self, val) return math.floor(100 * math.exp(PentaxEv(val - 32) * math.log(2)) + 0.5) end,
        ValueConvInv = function(_self, val) return PentaxEvInv(perl.log(val / 100) / math.log(2)) + 32 end,
    },
    [21] = { -- #PH
        Name = 'BaseExposureCompensation',
        Condition = function(self) return matches(self.Model, [[(K10D|GX10)\b]]) ~= nil end,
        Notes = 'K10D only; exposure compensation without auto bracketing',
        ValueConv = function(_self, val) return PentaxEv(64 - val) end,
        ValueConvInv = function(_self, val) return 64 - PentaxEvInv(val) end,
        PrintConv = function(_self, val) return val ~= 0 and sprintf('%+.1f', val) or 0 end,
        PrintConvInv = function(_self, val) return Exif.ConvertFraction(val) end,
    },
}

Pentax.AEInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    DATAMEMBER = { 7 },
    NOTES = 'Auto-exposure information for most Pentax models.',
    [0] = {
        Name = 'AEExposureTime',
        Notes = 'val = 24 * 2**((32-raw)/8)',
        ValueConv = function(_self, val) return 24 * math.exp(-(val - 32) * math.log(2) / 8) end,
        ValueConvInv = function(_self, val) return -perl.log(val / 24) * 8 / math.log(2) + 32 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return Exif.ConvertFraction(val) end,
    },
    [1] = {
        Name = 'AEAperture',
        Notes = 'val = 2**((raw-68)/16)',
        ValueConv = function(_self, val) return math.exp((val - 68) * math.log(2) / 16) end,
        ValueConvInv = function(_self, val) return perl.log(val) * 16 / math.log(2) + 68 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [2] = {
        Name = 'AE_ISO',
        Notes = 'val = 100 * 2**((raw-32)/8)',
        ValueConv = function(_self, val) return 100 * math.exp((val - 32) * math.log(2) / 8) end,
        ValueConvInv = function(_self, val) return perl.log(val / 100) * 8 / math.log(2) + 32 end,
        PrintConv = function(_self, val) return math.floor(val + 0.5) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [3] = {
        Name = 'AEXv',
        Notes = 'val = (raw-64)/8',
        ValueConv = function(_self, val) return (val - 64) / 8 end,
        ValueConvInv = function(_self, val) return val * 8 + 64 end,
    },
    [4] = {
        Name = 'AEBXv',
        Format = 'int8s',
        Notes = 'val = raw / 8',
        ValueConv = function(_self, val) return val / 8 end,
        ValueConvInv = function(_self, val) return val * 8 end,
    },
    [5] = { -- #19
        Name = 'AEMinExposureTime',
        Notes = 'val = 24 * 2**((32-raw)/8)',
        ValueConv = function(_self, val) return 24 * math.exp(-(val - 32) * math.log(2) / 8) end,
        ValueConvInv = function(_self, val) return -perl.log(val / 24) * 8 / math.log(2) + 32 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return Exif.ConvertFraction(val) end,
    },
    [6] = {
        Name = 'AEProgramMode',
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'M, P or TAv', [1] = 'Av, B or X', [2] = 'Tv', [3] = 'Sv or Green Mode',
            [8] = 'Hi-speed Program', [11] = 'Hi-speed Program (P-Shift)',
            [16] = 'DOF Program', [19] = 'DOF Program (P-Shift)', [24] = 'MTF Program',
            [27] = 'MTF Program (P-Shift)', [35] = 'Standard', [43] = 'Portrait',
            [51] = 'Landscape', [59] = 'Macro', [67] = 'Sport',
            [75] = 'Night Scene Portrait', [83] = 'No Flash', [91] = 'Night Scene',
            [99] = 'Surf & Snow', [104] = 'Night Snap', [107] = 'Text', [115] = 'Sunset',
            [123] = 'Kids', [131] = 'Pet', [139] = 'Candlelight', [144] = 'SCN',
            [160] = 'Program', [147] = 'Museum', [184] = 'Shallow DOF Program',
            [216] = 'HDR',
        },
    },
    [7] = {
        Name = 'AEFlags',
        Writable = 0,
        -- (this tag can't be unknown because the Hook must be evaluated to shift
        --  the following offsets if necessary -- indices after this are
        --  incremented by 1 when the record is larger than 20 bytes, e.g. the
        --  K-x's 24-byte AEInfo; upstream `Hook => '$size > 20 and $varSize += 1'`)
        Hook = function(_self, _format, _varSize, size) return size > 20 and 1 or 0 end,
        Notes = 'indices after this are incremented by 1 for some models',
        RawConv = function(self, val)
            if perl.truthy(self.OPTIONS.Unknown) then return val end
            return nil
        end,
        PrintConv = { BITMASK = {
            [3] = 'AE lock',
            [4] = 'Flash recommended?',
            [7] = 'Aperture wide open',
        } },
    },
    [8] = { -- #30
        Name = 'AEApertureSteps',
        Notes = [[
            number of steps the aperture has been stopped down from wide open.  There
            are roughly 8 steps per F-stop for most lenses, or 18 steps for 645D lenses,
            but it varies slightly by lens
        ]],
        PrintConv = function(_self, val) return val == 255 and 'n/a' or val end,
        PrintConvInv = function(_self, val) return val == 'n/a' and 255 or val end,
    },
    [9] = { -- #19
        Name = 'AEMaxAperture',
        Notes = 'val = 2**((raw-68)/16)',
        ValueConv = function(_self, val) return math.exp((val - 68) * math.log(2) / 16) end,
        ValueConvInv = function(_self, val) return perl.log(val) * 16 / math.log(2) + 68 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [10] = { -- #19
        Name = 'AEMaxAperture2',
        Notes = 'val = 2**((raw-68)/16)',
        ValueConv = function(_self, val) return math.exp((val - 68) * math.log(2) / 16) end,
        ValueConvInv = function(_self, val) return perl.log(val) * 16 / math.log(2) + 68 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [11] = { -- #19
        Name = 'AEMinAperture',
        Notes = 'val = 2**((raw-68)/16)',
        ValueConv = function(_self, val) return math.exp((val - 68) * math.log(2) / 16) end,
        ValueConvInv = function(_self, val) return perl.log(val) * 16 / math.log(2) + 68 end,
        PrintConv = function(_self, val) return sprintf('%.0f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [12] = { -- #19
        Name = 'AEMeteringMode',
        PrintConv = {
            [0] = 'Multi-segment',
            BITMASK = { [4] = 'Center-weighted average', [5] = 'Spot' },
        },
    },
    [13] = { -- #30
        Name = 'AEWhiteBalance',
        Condition = function(self) return self.AEInfoSize == 24 end, -- (not thoroughly tested for other sizes)
        Notes = 'K7 and Kx',
        Mask = 0xf0,
        PrintConv = {
            [0] = 'Standard', [1] = 'Daylight', [2] = 'Shade', [3] = 'Cloudy',
            [4] = 'Daylight Fluorescent', [5] = 'Day White Fluorescent',
            [6] = 'White Fluorescent', [7] = 'Tungsten', [8] = 'Unknown', -- #31
        },
    },
    [13.1] = { -- #30
        Name = 'AEMeteringMode2',
        Condition = function(self) return self.AEInfoSize == 24 end, -- (not thoroughly tested for other sizes)
        Notes = 'K7 and Kx, override for an incompatible metering mode setting',
        Mask = 0x0f,
        PrintConv = {
            [0] = 'Multi-segment',
            BITMASK = {
                [0] = 'Center-weighted average',
                [1] = 'Spot',
                -- 2 - seen for K7 AVI movie
            },
        },
    },
    [14] = { -- #19
        Name = 'FlashExposureCompSet',
        Description = 'Flash Exposure Comp. Setting',
        Format = 'int8s',
        Notes = [[
            reports the camera setting, unlike tag 0x004d which reports 0 in Green mode
            or if flash was on but did not fire.  Both this tag and 0x004d report the
            setting even if the flash is off
        ]],
        ValueConv = function(_self, val) return PentaxEv(val) end,
        ValueConvInv = function(_self, val) return PentaxEvInv(val) end,
        PrintConv = function(_self, val) return val ~= 0 and sprintf('%+.1f', val) or 0 end,
        PrintConvInv = function(_self, val) return Exif.ConvertFraction(val) end,
    },
    [21] = { -- #30
        Name = 'LevelIndicator',
        PrintConv = function(_self, val) return val == 90 and 'n/a' or val end,
        PrintConvInv = function(_self, val) return val == 'n/a' and 90 or val end,
    },
}

-- lens information (ref PH)
Pentax.LensInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    IS_SUBDIR = { 3 },
    NOTES = 'Pentax lens information structure for models such as the *istD.',
    [0] = {
        Name = 'LensType',
        Format = 'int8u[2]',
        Priority = 0,
        ValueConvInv = function(_self, val) return (str(val):gsub('%.%d+$', '')) end,
        PrintConv = pentaxLensTypes,
        SeparateTable = 1,
        PrintInt = 1,
    },
    [3] = {
        Name = 'LensData',
        Format = 'undef[17]',
        SubDirectory = { TagTable = 'lexiftool.Pentax.LensData' },
    },
}

-- lens information for newer models (ref PH)
Pentax.LensInfo2 = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    IS_SUBDIR = { 4 },
    NOTES = 'Pentax lens information structure for models such as the K10D and K20D.',
    [0] = {
        Name = 'LensType',
        Format = 'int8u[4]',
        Priority = 0,
        ValueConv = function(_self, val)
            local v = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do v[#v + 1] = tonumber(w) end
            v[1] = v[1] & 0x0f
            v[2] = v[3] * 256 + v[4] -- (always high byte first)
            return v[1] .. ' ' .. v[2]
        end,
        ValueConvInv = function(_self, val)
            local v = perl.split(' ', val)
            if #v ~= 2 then return nil end
            v[3] = (perl.int(v[2]) >> 8) & 0xff
            v[4] = perl.int(v[2]) & 0xff
            v[2] = 0
            return perl.join(' ', v)
        end,
        PrintConv = pentaxLensTypes,
        SeparateTable = 1,
        PrintInt = 1,
    },
    [4] = {
        Name = 'LensData',
        Format = 'undef[17]',
        SubDirectory = { TagTable = 'lexiftool.Pentax.LensData' },
    },
}

-- lens information for 645D (ref PH)
Pentax.LensInfo3 = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    IS_SUBDIR = { 13 },
    NOTES = 'Pentax lens information structure for 645D.',
    [1] = {
        Name = 'LensType',
        Format = 'int8u[4]',
        Priority = 0,
        ValueConv = function(_self, val)
            local v = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do v[#v + 1] = tonumber(w) end
            v[1] = v[1] & 0x0f
            v[2] = v[3] * 256 + v[4] -- (always high byte first)
            return v[1] .. ' ' .. v[2]
        end,
        -- just fill in the missing bits/bytes with zeros...
        ValueConvInv = function(_self, val)
            local v = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do v[#v + 1] = tonumber(w) end
            if #v ~= 2 then return nil end
            v[3] = (v[2] >> 8) & 0xff
            v[4] = v[2] & 0xff
            v[2] = 0
            return table.concat(v, ' ')
        end,
        PrintConv = pentaxLensTypes,
        SeparateTable = 1,
        PrintInt = 1,
    },
    [13] = {
        Name = 'LensData',
        Format = 'undef[17]',
        SubDirectory = { TagTable = 'lexiftool.Pentax.LensData' },
    },
}

-- lens information for K-5, K-r, etc (ref PH)
Pentax.LensInfo4 = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    IS_SUBDIR = { 12 },
    NOTES = 'Pentax lens information structure for models such as the K-5 and K-r.',
    [1] = {
        Name = 'LensType',
        Format = 'int8u[4]',
        Priority = 0,
        ValueConv = function(_self, val)
            local v = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do v[#v + 1] = tonumber(w) end
            v[1] = v[1] & 0x0f
            v[2] = v[3] * 256 + v[4] -- (always high byte first)
            return v[1] .. ' ' .. v[2]
        end,
        -- just fill in the missing bits/bytes with zeros...
        ValueConvInv = function(_self, val)
            local v = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do v[#v + 1] = tonumber(w) end
            if #v ~= 2 then return nil end
            v[3] = (v[2] >> 8) & 0xff
            v[4] = v[2] & 0xff
            v[2] = 0
            return table.concat(v, ' ')
        end,
        PrintConv = pentaxLensTypes,
        SeparateTable = 1,
        PrintInt = 1,
    },
    [12] = {
        Name = 'LensData',
        Format = 'undef[18]',
        Condition = function(self) self.NewLensData = 1; return true end, -- not really a condition, just used to set flag
        SubDirectory = { TagTable = 'lexiftool.Pentax.LensData' },
    },
}

-- lens information for K-01, K-30, K-50, K-500, K-3, K-3II, K-S1 (ref PH)
Pentax.LensInfo5 = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    IS_SUBDIR = { 15 },
    NOTES = 'Pentax lens information structure for the K-01 and newer models.',
    [1] = {
        Name = 'LensType',
        Format = 'int8u[5]',
        Priority = 0,
        ValueConv = function(_self, val)
            local v = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do v[#v + 1] = tonumber(w) end
            v[1] = v[1] & 0x0f
            v[2] = v[4] * 256 + v[5] -- (always high byte first)
            return v[1] .. ' ' .. v[2]
        end,
        -- just fill in the missing bits/bytes with zeros...
        ValueConvInv = function(_self, val)
            local v = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do v[#v + 1] = tonumber(w) end
            if #v ~= 2 then return nil end
            v[4] = (v[2] >> 8) & 0xff
            v[5] = v[2] & 0xff
            v[2], v[3] = 0, 0
            return table.concat(v, ' ')
        end,
        PrintConv = pentaxLensTypes,
        SeparateTable = 1,
        PrintInt = 1,
    },
    [15] = {
        Name = 'LensData',
        Format = 'undef[17]',
        SubDirectory = { TagTable = 'lexiftool.Pentax.LensData' },
    },
}

-- lens data information, including lens codes (ref PH)
Pentax.LensData = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    DATAMEMBER = { 12.1 },
    NOTES = [[
        Pentax lens data information.  Some of these tags require interesting binary
        gymnastics to decode them into useful values.
    ]],
    -- this byte comes from the lens electrical contacts
    -- (see http://kmp.bdimitrov.de/technology/K-mount/Ka.html)
    [0.1] = { -- #JD
        Name = 'AutoAperture',
        Condition = function(self) return not self.NewLensData end,
        Notes = 'not valid for the K-r, K-5 or K-5II', -- #29
        Mask = 0x01,
        PrintConv = { [0] = 'On', [1] = 'Off' },
    },
    [0.2] = { -- #JD
        Name = 'MinAperture',
        Condition = function(self) return not self.NewLensData end,
        Notes = 'not valid for the K-r, K-5 or K-5II', -- #29
        Mask = 0x06,
        PrintConv = { [0] = 22, [1] = 32, [2] = 45, [3] = 16 },
    },
    [0.3] = { -- #JD
        Name = 'LensFStops',
        Condition = function(self) return not self.NewLensData end,
        Notes = 'not valid for the K-r, K-5 or K-5II', -- #29
        Mask = 0x70,
        ValueConv = function(_self, val) return 5 + ((val ~ 0x07) / 2) end,
        ValueConvInv = function(_self, val) return ((val - 5) * 2) ~ 0x07 end,
    },
    -- 1-16 look like Lens Codes LC0-LC15, ref patent 5617173 and 5999753 [+notes by PH]
    [1] = lensCode { -- LC0 = lens kind + version data
        Name = 'LensKind',
    },
    [2] = lensCode { -- LC1 = lens data (changes with AF setting)
        Name = 'LC1',
    },
    -- LC2 = distance data
    [3] = { -- #29
        Name = 'MinFocusDistance',
        Notes = 'minimum focus distance for the lens',
        Mask = 0xf8,
        PrintConv = {
            [0] = '0.13-0.19 m', [1] = '0.20-0.24 m', [2] = '0.25-0.28 m',
            [3] = '0.28-0.30 m', [4] = '0.35-0.38 m', [5] = '0.40-0.45 m',
            [6] = '0.49-0.50 m', [7] = '0.6 m', [8] = '0.7 m', [9] = '0.8-0.9 m',
            [10] = '1.0 m', [11] = '1.1-1.2 m', [12] = '1.4-1.5 m', [13] = '1.5 m',
            [14] = '2.0 m', [15] = '2.0-2.1 m', [16] = '2.1 m', [17] = '2.2-2.9 m',
            [18] = '3.0 m', [19] = '4-5 m', [20] = '5.6 m',
        },
    },
    [3.1] = { -- #29
        Name = 'FocusRangeIndex',
        Mask = 0x07,
        PrintConv = {
            [7] = '0 (very close)', [6] = '1 (close)', [4] = '2', [5] = '3',
            [1] = '4', [0] = '5', [2] = '6 (far)', [3] = '7 (very far)',
        },
    },
    [4] = lensCode { -- LC3 = K-value data (AF pulses to displace image by unit length)
        Name = 'LC3',
    },
    [5] = lensCode { -- LC4 = aberration correction, near distance data
        Name = 'LC4',
    },
    [6] = lensCode { -- LC5 = light color aberration correction data
        Name = 'LC5',
    },
    [7] = lensCode { -- LC6 = open aberration data
        Name = 'LC6',
    },
    [8] = lensCode { -- LC7 = AF minimum actuation condition
        Name = 'LC7',
    },
    [9] = {
        { -- LC8 = focal length data
            Name = 'LensFocalLength',
            Notes = 'focal length of lens alone, without adapter', -- #PH
            Priority = 0,
            Condition = function(self) return matches(str(self.Model or ''), [==[645Z]==]) == nil end, -- #PH (doesn't work for 645Z)
            ValueConv = function(_self, val) return 10 * (val >> 2) * (4 ^ ((val & 0x03) - 2)) end, -- #JD
            ValueConvInv = function(_self, val)
                local range = perl.int(perl.log(val / 10) / (2 * math.log(2)))
                if range < 0 or range > 3 then error('Value out of range', 0) end
                return range + (perl.int(val / (10 * 4 ^ (range - 2)) + 0.5) << 2)
            end,
            PrintConv = function(_self, val) return sprintf('%.1f mm', val) end,
            PrintConvInv = function(_self, val) return (str(val):gsub('[ \t\n\r\f\v]*mm', '')) end,
        },
        lensCode {
            Name = 'LC8',
        },
    },
    -- the following aperture values change with focal length
    [10] = { -- LC9 = nominal AVmin/AVmax data (open/closed aperture values)
        Name = 'NominalMaxAperture',
        Mask = 0xf0,
        ValueConv = function(_self, val) return 2 ^ (val / 4) end, -- #JD
        ValueConvInv = function(_self, val) return 4 * math.log(val) / math.log(2) end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [10.1] = { -- LC9 = nominal AVmin/AVmax data (open/closed aperture values)
        Name = 'NominalMinAperture',
        Mask = 0x0f,
        ValueConv = function(_self, val) return 2 ^ ((val + 10) / 4) end, -- #JD
        ValueConvInv = function(_self, val) return 4 * math.log(val) / math.log(2) - 10 end,
        PrintConv = function(_self, val) return sprintf('%.0f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    -- LC10 = mv'/nv' data (full-aperture metering error compensation/marginal lumination compensation)
    [11] = lensCode {
        Name = 'LC10',
    },
    [12] = lensCode { -- LC11 = AVC 1/EXP data
        Name = 'LC11',
    },
    [12.1] = {
        Name = 'NewLensDataHook',
        Hidden = 1,
        Hook = function(self) return self.NewLensData and 1 or 0 end,
        RawConv = function() return nil end,
    },
    [13] = lensCode { -- LC12 = mv1 AVminsif data
        Name = 'LC12',
        Notes = "ID's 13-16 are offset by 1 for the K-r, K-5 and K-5II", -- #29
    },
    -- 14 - related to live view for K-5 (normally 3, but 1 or 5 in LV mode)
    [14.1] = { -- LC13 = AVmin (open aperture value) [MaxAperture=(2**((AVmin-1)/32))]
        Name = 'MaxAperture',
        Condition = function(self) return self.Model ~= 'K-5' end,
        Notes = 'effective wide open aperture for current focal length',
        Mask = 0x7f, -- (not sure what the high bit indicates)
        -- (a value of 1 seems to indicate 'n/a')
        RawConv = function(_self, val) return val > 1 and val or nil end,
        ValueConv = function(_self, val) return 2 ^ ((val - 1) / 32) end,
        ValueConvInv = function(_self, val) return 32 * math.log(val) / math.log(2) + 1 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [15] = lensCode { -- LC14 = UNT_12 UNT_6 data
        Name = 'LC14',
    },
    [16] = lensCode { -- LC15 = incorporated flash suited END data
        Name = 'LC15',
    },
}

Pentax.FlashInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'Flash information tags for the K10D, K20D and K200D.',
    [0] = {
        Name = 'FlashStatus',
        PrintHex = 1,
        PrintConv = { -- #19
            [0x00] = 'Off', [0x01] = 'Off (1)', [0x02] = 'External, Did not fire',
            [0x06] = 'External, Fired', [0x08] = 'Internal, Did not fire (0x08)',
            [0x09] = 'Internal, Did not fire', [0x0d] = 'Internal, Fired',
        },
    },
    [1] = {
        Name = 'InternalFlashMode',
        PrintHex = 1,
        PrintConv = {
            [0x00] = 'n/a - Off-Auto-Aperture', [0x86] = 'Fired, Wireless (Control)',
            [0x95] = 'Fired, Wireless (Master)', [0xc0] = 'Fired',
            [0xc1] = 'Fired, Red-eye reduction', [0xc2] = 'Fired, Auto',
            [0xc3] = 'Fired, Auto, Red-eye reduction',
            [0xc6] = 'Fired, Wireless (Control), Fired normally not as control',
            [0xc8] = 'Fired, Slow-sync', [0xc9] = 'Fired, Slow-sync, Red-eye reduction',
            [0xca] = 'Fired, Trailing-curtain Sync', [0xf0] = 'Did not fire, Normal',
            [0xf1] = 'Did not fire, Red-eye reduction', [0xf2] = 'Did not fire, Auto',
            [0xf3] = 'Did not fire, Auto, Red-eye reduction',
            [0xf4] = 'Did not fire, (Unknown 0xf4)',
            [0xf5] = 'Did not fire, Wireless (Master)',
            [0xf6] = 'Did not fire, Wireless (Control)', [0xf8] = 'Did not fire, Slow-sync',
            [0xf9] = 'Did not fire, Slow-sync, Red-eye reduction',
            [0xfa] = 'Did not fire, Trailing-curtain Sync',
        },
    },
    [2] = {
        Name = 'ExternalFlashMode',
        PrintHex = 1,
        PrintConv = {
            [0x00] = 'n/a - Off-Auto-Aperture', [0x3f] = 'Off', [0x40] = 'On, Auto',
            [0xbf] = 'On, Flash Problem', [0xc0] = 'On, Manual', [0xc4] = 'On, P-TTL Auto',
            [0xc5] = 'On, Contrast-control Sync', [0xc6] = 'On, High-speed Sync',
            [0xcc] = 'On, Wireless', [0xcd] = 'On, Wireless, High-speed Sync',
            [0xf0] = 'Not Connected',
        },
    },
    [3] = {
        Name = 'InternalFlashStrength',
        Notes = 'saved from the most recent flash picture, on a scale of about 0 to 100',
    },
    [4] = 'TTL_DA_AUp',
    [5] = 'TTL_DA_ADown',
    [6] = 'TTL_DA_BUp',
    [7] = 'TTL_DA_BDown',
    [24.1] = { -- #19/17
        Name = 'ExternalFlashGuideNumber',
        Mask = 0x1f,
        Notes = 'val = 2**(raw/16 + 4), with a few exceptions',
        ValueConv = function(_self, val)
            if val == 0 then return 0 end
            if val == 29 then val = -3 end
            return 2 ^ (val / 16 + 4)
        end,
        ValueConvInv = function(_self, val)
            if not perl.truthy(val) then return 0 end
            local raw = perl.int((perl.log(val) / math.log(2) - 4) * 16 + 0.5)
            if raw < 0 then raw = 29 end   -- guide number of 14 gives -3 which is stored as 0x1d
            if raw > 31 then raw = 31 end  -- maximum value is 0x1f
            return raw
        end,
        PrintConv = function(_self, val) return val ~= 0 and math.floor(val + 0.5) or 'n/a' end,
        PrintConvInv = function(_self, val) if perl.isMatch(val, '^n') then return 0 end return val end,
    },
    [25] = { -- #19
        Name = 'ExternalFlashExposureComp',
        PrintConv = {
            [0] = 'n/a', [144] = 'n/a (Manual Mode)', [164] = '-3.0', [167] = '-2.5',
            [168] = '-2.0', [171] = '-1.5', [172] = '-1.0', [175] = '-0.5',
            [176] = '0.0', [179] = '0.5', [180] = '1.0',
        },
    },
    [26] = { -- #17
        Name = 'ExternalFlashBounce',
        Notes = 'saved from the most recent external flash picture', -- #19
        PrintConv = { [0] = 'n/a', [16] = 'Direct', [48] = 'Bounce' },
    },
}

-- unknown flash information (Q, Q10)
Pentax.FlashInfoUnknown = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
}

Pentax.CameraInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FORMAT = 'int32u',
    [0] = {
        Name = 'PentaxModelID',
        Priority = 0, -- (Optio SVi uses incorrect Optio SV ID here)
        SeparateTable = 1,
        PrintHex = 1,
        PrintConv = pentaxModelID,
    },
    [1] = {
        Name = 'ManufactureDate',
        Groups = { [2] = 'Time' },
        Notes = [[
            this value, and the values of the tags below, may change if the camera is
            serviced
        ]],
        ValueConv = function(_self, val)
            val = str(val)
            local y, m, d = val:match('^(%d%d%d%d)(%d%d)(%d%d)$')
            if y then return y .. ':' .. m .. ':' .. d end
            y, m, d = val:match('^(%d)(%d%d)(%d%d)$')
            if y then return '200' .. y .. ':' .. m .. ':' .. d end
            return 'Unknown (' .. val .. ')'
        end,
        ValueConvInv = function(_self, val) return (perl.tr(val, '0-9', '', 'dc')) end,
    },
    [2] = {
        Name = 'ProductionCode', -- (previously ModelRevision)
        Format = 'int32u[2]',
        Note = 'values of 8.x indicate that the camera has been serviced',
        ValueConv = function(_self, val) return (str(val):gsub(' ', '.')) end,
        ValueConvInv = function(_self, val) return (perl.tr(val, '.', ' ')) end,
        PrintConv = function(_self, val)
            local s = str(val)
            if s:match('^8%.') then return s .. ' (camera has been serviced)' end
            return s
        end,
        PrintConvInv = function(_self, val) return (subst(val, [[(?s)\s+.*]], '')) end,
    },
    [4] = 'InternalSerialNumber',
}

Pentax.BatteryInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
-- size of data:
-- 4 (K-m,K2000=4xAA), 6 (*istD,K10D,K100D,K110D=2xCR-V3/4xAA),
-- 7 (K20D=D-LI50, K200D=4xAA), 8 (645D=D-LI90), 10 (K-r pre-production?),
-- 14 (K-7=D-LI90, K-r=D-LI109/4xAA, K-x=4xAA), 26 (K-5=D-LI90)
-- battery grips available for:
-- BG1 (*istD), BG2 (K10D/K20D), BG3 (K200D), BG4 (K-7,K-5)
-- no grip available: K-x
    [0.1] = {
        { -- #19
            Name = 'PowerSource',
            Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) == nil end,
            Mask = 0x0f,
            -- have seen the upper bit set (value of 0x82) for the
            -- *istDS and K100D, but I'm not sure what this means - PH
            -- I've also seen: 0x42 (K2000), 0xf2 (K-7,K-r,K-5), 0x12,0x22 (K-x) - PH
            PrintConv = {
                [1] = 'Camera Battery', -- #PH (NC, GR III)
                [2] = 'Body Battery',
                [3] = 'Grip Battery',
                [4] = 'External Power Supply', -- #PH
            },
        },
        { -- #PH (forum15976)
            Name = 'PowerSource',
            Mask = 0x0f,
            Notes = 'K-3III',
            -- have seen the upper bit set (value of 0x82) for the
            -- *istDS and K100D, but I'm not sure what this means - PH
            -- I've also seen: 0x42 (K2000), 0xf2 (K-7,K-r,K-5), 0x12,0x22 (K-x) - PH
            PrintConv = {
                [1] = 'Body Battery',
                [2] = 'Grip Battery',
                [4] = 'External Power Supply',
            },
        },
    },
    [0.2] = {
        Name = 'PowerAvailable',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
        Notes = 'K-3III',
        Mask = 0xf0,
        PrintConv = { BITMASK = {
            [0] = 'Body Battery',
            [1] = 'Grip Battery',
            [3] = 'External Power Supply',
        } },
    },
    [1.1] = {
        {
            Name = 'BodyBatteryState',
            Condition = function(self) return matches(str(self.Model or ''), [==[(\*ist|K100D|K200D|K10D|GX10|K20D|GX20|GX-1[LS]?)\b]==]) ~= nil end,
            Notes = '*istD, K100D, K200D, K10D and K20D',
            Mask = 0xf0,
            PrintConv = { -- #19
                [1] = 'Empty or Missing',
                [2] = 'Almost Empty',
                [3] = 'Running Low',
                [4] = 'Full',
            },
        },
        {
            Name = 'BodyBatteryState',
            Condition = function(self) return matches(str(self.Model or ''), [==[(K110D|K2000|K-m|K-3 Mark III)\b]==]) == nil end,
            Notes = 'most other models except the K110D, K2000, K-m and K-3III',
            Mask = 0xf0,
            PrintConv = {
                [1] = 'Empty or Missing',
                [2] = 'Almost Empty',
                [3] = 'Running Low',
                [4] = 'Close to Full',
                [5] = 'Full',
            },
        },
    },
    [1.2] = {
        {
            Name = 'GripBatteryState',
            Condition = function(self) return matches(str(self.Model or ''), [==[(K10D|GX10|K20D|GX20)\b]==]) ~= nil end,
            Notes = 'K10D and K20D',
            Mask = 0x0f,
            PrintConv = { -- #19
                [1] = 'Empty or Missing',
                [2] = 'Almost Empty',
                [3] = 'Running Low',
                [4] = 'Full',
            },
        },
    },
    -- internal and grip battery voltage Analogue to Digital measurements,
    -- open circuit and under load
    [2] = {
        {
            Name = 'BodyBatteryADNoLoad',
            Description = 'Body Battery A/D No Load',
            Condition = function(self) return matches(str(self.Model or ''), [==[(K10D|GX10|K20D|GX20)\b]==]) ~= nil end,
            Notes = 'roughly calibrated for K10D with a new Pentax battery',
            -- rough linear calibration drops quickly below 30% - PH
            -- DVM readings: 8.18V=186, 8.42-8.40V=192 (full), 6.86V=155 (empty)
            PrintConv = function(_self, val)
                return sprintf('%d (%.1fV, %d%%)', val, val * 8.18 / 186, math.floor((val - 155) * 100 / 35))
            end,
            PrintConvInv = function(_self, val) return (str(val):gsub(' .*', '')) end,
        },
        {
            Name = 'BodyBatteryADNoLoad',
            Description = 'Body Battery A/D No Load',
            Condition = function(self) return matches(str(self.Model or ''), [==[(\*ist|K100D|K200D|GX-1[LS]?)\b]==]) ~= nil end,
        },
        {
            Name = 'BodyBatteryVoltage1', -- (static?)
            Condition = function(self)
                local m = str(self.Model or '')
                return matches(m, [==[(645D|645Z|K-(1|01|3|5|7|30|50|70|500|r|x|S[12])|KP)\b]==]) ~= nil and
                       matches(m, [==[III]==]) == nil
            end,
            Format = 'int16u',
            ValueConv = function(_self, val) return val / 100 end,
            ValueConvInv = function(_self, val) return val * 100 end,
            PrintConv = function(_self, val) return sprintf('%.2f V', val) end,
            PrintConvInv = function(_self, val) return (str(val):gsub('[ \t\n\r\f\v]*V$', '')) end,
            -- For my K-5:          Min (0%) Max (100%) At Meas
            -- BodyBatteryVoltage1  6.24 V   7.75 V     7.66 V
            -- BodyBatteryVoltage2  5.98 V   7.43 V     7.34 V
            -- BodyBatteryVoltage3  6.41 V   7.93 V     7.84 V
            -- BodyBatteryVoltage4  6.10 V   7.55 V     7.45 V
            -- "Meas" open-circuit voltages with DVM: AB=0V, AC=+8.33V, BC=+8.22V
            -- (terminal "C" is closest to edge of battery)
        },
        {
            Name = 'BodyBatteryState',
            Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
            Notes = 'K-3III',
            PrintConv = {
                [0] = 'Empty or Missing',
                [1] = 'Almost Empty',
                [2] = 'Running Low',
                [3] = 'Half Full',
                [4] = 'Close to Full',
                [5] = 'Full',
            },
        }
    },
    [3] = {
        {
            Name = 'BodyBatteryADLoad',
            Description = 'Body Battery A/D Load',
            Condition = function(self) return matches(str(self.Model or ''), [==[(K10D|GX10|K20D|GX20)\b]==]) ~= nil end,
            Notes = 'roughly calibrated for K10D with a new Pentax battery',
            -- [have seen 187] - PH
            PrintConv = function(_self, val)
                return sprintf('%d (%.1fV, %d%%)', val, val * 8.18 / 186, math.floor((val - 152) * 100 / 34))
            end,
            PrintConvInv = function(_self, val) return (str(val):gsub(' .*', '')) end,
        },
        {
            Name = 'BodyBatteryADLoad',
            Description = 'Body Battery A/D Load',
            Condition = function(self) return matches(str(self.Model or ''), [==[(\*ist|K100D|K200D)\b]==]) ~= nil end,
        },
        {
            Name = 'BodyBatteryPercent',
            Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
            Notes = 'K-3III',
        }
    },
    [4] = {
        {
            Name = 'GripBatteryADNoLoad',
            Description = 'Grip Battery A/D No Load',
            Condition = function(self) return matches(str(self.Model or ''), [==[(\*ist|K10D|GX10|K20D|GX20|GX-1[LS]?)\b]==]) ~= nil end,
        },
        {
            Name = 'BodyBatteryVoltage2', -- (less than BodyBatteryVoltage1 -- under load?)
            Condition = function(self)
                local m = str(self.Model or '')
                return matches(m, [==[(645D|645Z|K-(1|01|3|5|7|30|50|70|500|r|x|S[12])|KP)\b]==]) ~= nil and
                       matches(m, [==[III]==]) == nil
            end,
            Format = 'int16u',
            ValueConv = function(_self, val) return val / 100 end,
            ValueConvInv = function(_self, val) return val * 100 end,
            PrintConv = function(_self, val) return sprintf('%.2f V', val) end,
            PrintConvInv = function(_self, val) return (str(val):gsub('[ \t\n\r\f\v]*V$', '')) end,
        },
        {
            Name = 'BodyBatteryVoltage',
            Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
            Format = 'int32u',
            ValueConv = function(_self, val) return val * 4e-8 + 0.27219 end,
            ValueConvInv = function(_self, val) return (val - 0.27219) / 4e-8 end,
            PrintConv = function(_self, val) return sprintf('%.2f V', val) end,
            PrintConvInv = function(_self, val) return (str(val):gsub('[ \t\n\r\f\v]*V$', '')) end,
        },
    },
    [5] = {
        Name = 'GripBatteryADLoad',
        Condition = function(self) return matches(str(self.Model or ''), [==[(\*ist|K10D|GX10|K20D|GX20)\b]==]) ~= nil end,
        Description = 'Grip Battery A/D Load',
    },
    [6] = {
        Name = 'BodyBatteryVoltage3', -- (greater than BodyBatteryVoltage1)
        Condition = function(self) return matches(str(self.Model or ''), [==[(K-5|K-r|645D)\b]==]) ~= nil end,
        Format = 'int16u',
        Notes = 'K-5, K-r and 645D only',
        ValueConv = function(_self, val) return val / 100 end,
        ValueConvInv = function(_self, val) return val * 100 end,
        PrintConv = function(_self, val) return sprintf('%.2f V', val) end,
        PrintConvInv = function(_self, val) return (str(val):gsub('[ \t\n\r\f\v]*V$', '')) end,
    },
    [8] = {
        Name = 'BodyBatteryVoltage4', -- (between BodyBatteryVoltage1 and BodyBatteryVoltage2)
        Condition = function(self) return matches(str(self.Model or ''), [==[(K-5|K-r)\b]==]) ~= nil end,
        Format = 'int16u',
        Notes = 'K-5 and K-r only',
        ValueConv = function(_self, val) return val / 100 end,
        ValueConvInv = function(_self, val) return val * 100 end,
        PrintConv = function(_self, val) return sprintf('%.2f V', val) end,
        PrintConvInv = function(_self, val) return (str(val):gsub('[ \t\n\r\f\v]*V$', '')) end,
    },
    [16] = {
        Name = 'GripBatteryState',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
        Notes = 'K-3III',
        PrintConv = {
            [0] = 'Empty or Missing',
            [1] = 'Almost Empty',
            [2] = 'Running Low',
            [3] = 'Half Full',
            [4] = 'Close to Full',
            [5] = 'Full',
        },
    },
    [17] = {
        Name = 'GripBatteryPercent',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
        Notes = 'K-3III',
    },
    [18] = {
        Name = 'GripBatteryVoltage',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
        Notes = 'K-3III',
        Format = 'int32u',
        ValueConv = function(_self, val) return val * 4e-8 + 0.27219 end,
        ValueConvInv = function(_self, val) return (val - 0.27219) / 4e-8 end,
        PrintConv = function(_self, val) return sprintf('%.2f V', val) end,
        PrintConvInv = function(_self, val) return (str(val):gsub('[ \t\n\r\f\v]*V$', '')) end,
    },
}

Pentax.AFInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    -- AF Info tag names in K10D debugging output - PH:
    -- SelectArea, InFocusArea, Predictor, Defocus, IntegTime2msStep,
    -- CalFlag, ContrastFlag, PrecalFlag, SelectSensor
    [0x00] = { -- #PH
        Name = 'AFPointsUnknown1',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) == nil end, -- (and maybe others?)
        Unknown = 1,
        Format = 'int16u',
        ValueConv = function(self, val) return perl.truthy(self:Options('Unknown')) and val or (val & 0x7ff) end,
        ValueConvInv = function(_self, val) return val end,
        PrintConvColumns = 2,
        PrintConv = {
            [0] = '(none)',
            [0x07ff] = 'All',
            [0x0777] = 'Central 9 points',
            BITMASK = {
                [0] = 'Upper-left',
                [1] = 'Top',
                [2] = 'Upper-right',
                [3] = 'Left',
                [4] = 'Mid-left',
                [5] = 'Center',
                [6] = 'Mid-right',
                [7] = 'Right',
                [8] = 'Lower-left',
                [9] = 'Bottom',
                [10] = 'Lower-right',
                -- (bits 12-15 are flags of some sort)
            },
        },
    },
    [0x02] = { -- #PH
        Name = 'AFPointsUnknown2',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) == nil end, -- (and maybe others?)
        Unknown = 1,
        Format = 'int16u',
        ValueConv = function(self, val) return perl.truthy(self:Options('Unknown')) and val or (val & 0x7ff) end,
        ValueConvInv = function(_self, val) return val end,
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'Auto',
            BITMASK = {
                [0] = 'Upper-left',
                [1] = 'Top',
                [2] = 'Upper-right',
                [3] = 'Left',
                [4] = 'Mid-left',
                [5] = 'Center',
                [6] = 'Mid-right',
                [7] = 'Right',
                [8] = 'Lower-left',
                [9] = 'Bottom',
                [10] = 'Lower-right',
                -- (bits 12-15 are flags of some sort)
                -- bit 15 is set for center focus point only if it is vertical
            },
        },
    },
    [0x04] = { -- #PH (educated guess - predicted amount to drive lens)
        Name = 'AFPredictor',
        Format = 'int16s',
    },
    [0x06] = 'AFDefocus', -- #PH (educated guess - calculated distance from focused)
    [0x07] = { -- #PH
        -- effective exposure time for AF sensors in 2 ms increments
        Name = 'AFIntegrationTime',
        Notes = 'times less than 2 ms give a value of 0',
        ValueConv = function(_self, val) return val * 2 end,
        ValueConvInv = function(_self, val) return math.floor(val / 2) end, -- (don't round up)
        PrintConv = function(_self, val) return perl.str(val) .. ' ms' end,
        PrintConvInv = function(_self, val) return (str(val):gsub('%D', '')) end,
    },
    -- 0x0a - values: 00,05,0d,15,86,8e,a6,ae
    [0x0b] = { -- #JD
        Name = 'AFPointsInFocus',
        Condition = function(self) return matches(str(self.Model or ''), [==[(K-(1|3|70|S1|S2)|KP)\b]==]) == nil end,  -- #KG: valid also for K-S1/S2
        Notes = [[
            models other than the K-1, K-3, K-70, KP and K-S1/S2. May report two points
            in focus even though a single AFPoint has been selected, in which case the
            selected AFPoint is the first reported
        ]],
        PrintConvColumns = 2,
        PrintConv = {
            [0] = 'None',
            [1] = 'Lower-left, Bottom',
            [2] = 'Bottom',
            [3] = 'Lower-right, Bottom',
            [4] = 'Mid-left, Center',
            [5] = 'Center (horizontal)', -- #PH
            [6] = 'Mid-right, Center',
            [7] = 'Upper-left, Top',
            [8] = 'Top',
            [9] = 'Upper-right, Top',
            [10] = 'Right',
            [11] = 'Lower-left, Mid-left',
            [12] = 'Upper-left, Mid-left',
            [13] = 'Bottom, Center',
            [14] = 'Top, Center',
            [15] = 'Lower-right, Mid-right',
            [16] = 'Upper-right, Mid-right',
            [17] = 'Left',
            [18] = 'Mid-left',
            [19] = 'Center (vertical)', -- #PH
            [20] = 'Mid-right',
        },
    },
    [0x14] = {
        Name = 'AFPointValues',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end, -- #KG
        Format = 'int16uRev[69]',
        Unknown = 1,
        Notes = 'some unknown values related to each AFPoint',
        -- order is the same as AFPointsSelected below, but there is an additional value for
        -- each AF point starting at offset 28 in the array (yes, the range overlaps
        -- with the 1st values)
        -- (values are int16s stored in reversed byte order)
        ValueConv = function(_self, val)
            local a = {}
            for w in str(val):gmatch('[^ \t\n\r\f\v]+') do
                local n = tonumber(w)
                if n > 32767 then n = n - 65536 end
                a[#a + 1] = n
            end
            return table.concat(a, ' ')
        end,
        PrintConv = function(self, val) return AFPointValuesK3III(val, self) end,
    },
    [0x12a] = {
        Name = 'AFPointsSelected', -- (should probably be "AFPointSelected", but the bitmask allows multiple points)
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
        Notes = [[
            K-3III only. 41 selectable AF points from a total of 101 available in a 13x9
            grid. Columns are labelled A-M and rows are 1-9. The center point is G5. The
            exact meaning of this tag is not fully understood, although it does seem
            related to the selected AF point
        ]],
        Format = 'int8u[101]',
        -- value of 1 means "selected point", and 2 means "center of selected area"
        PrintConv = function(self, val) return AFPointNamesK3III(val, self) end,
    },
--
-- (maybe not coincidentally, there are 60 unknown bytes
--  here, and there are also 60 non-selectable AF points)
--
    [0x18f] = { -- byte has a value of 1 if corresponding AF point is ... in focus maybe?
        -- usually the same points as AFPointsSelected above, but not always
        Name = 'AFPointsUnknown',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end, -- #KG
        Unknown = 1,
        Format = 'int8u[101]',
        PrintConv = function(self, val) return AFPointNamesK3III(val, self) end,
    },
    [0x1fa] = {
        Name = 'LiveView',
        Notes = 'decoded only for the K-3 III',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end, -- #KG
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x1fd] = {
        Name = 'AFHold',
        Notes = 'decoded only for the K-3 II',
        Condition = function(self) return self.Model == 'PENTAX K-3 II' end,
        PrintConv = { [0] = 'Off', [1] = 'Short', [2] = 'Medium', [3] = 'Long' },
    },
    [0x021f] = { -- #KG
        Name = 'FirstFrameActionInAFC',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
        PrintConv = {
            ['0']   = 'Auto',
            ['1']   = 'Release Priority',
            ['2']   = 'Focus Priority',
            -- there is at least another value '3' but I couldn't figure out the
            -- meaning. However, this occurs for a few AF-S captures, so it has
            -- no real practical meaning.
        },
    },
    [0x0220] = { -- #KG
        Name = 'ActionInAFCCont',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
        PrintConv = {
            ['0']   = 'Auto',
            ['1']   = 'Focus Priority',
            ['2']   = 'FPS Priority',
        },
    },
    [545] = { -- #KG
        Name = 'AFCHold',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
        Mask = 0x03,
        PrintConv = { [0] = 'Low', [1] = 'Medium', [2] = 'High', [3] = 'Off' },
    },
    [545.1] = { -- #KG
        Name = 'AFCPointTracking',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
        Mask = 0x0c,
        PrintConv = { [0] = 'Type 1', [1] = 'Type 2', [2] = 'Type 3' },
    },
    [545.2] = { -- #KG
        Name = 'AFCSensitivity',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
        Mask = 0x70,
        PrintConv = function(_self, val) return 5 - val end,
        PrintConvInv = function(_self, val) return 5 - val end,
    },
    [0x0960] = { -- #KG
        Name = 'SubjectRecognition',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-3 Mark III]==]) ~= nil end,
        PrintConv = {
            [0] = 'Off',
            [1] = 'On',
        },
    },
}

-- contrast-detect AF-point information (ref KarstenGieselmann)
Pentax.CAFPointInfo = binaryDataAttrs {
    FIRST_ENTRY = 0,
    DATAMEMBER = { 1 },
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'Contrast-detect AF-point information for the K-01 and later models.',
    [1] = {
        Name = 'NumCAFPoints',
        RawConv = function(self, val) self.NumCAFPoints = (val & 0x0f) * (val >> 4); return val end,
        ValueConv = function(_self, val) return (val >> 4) * (val & 0x0f) end,
    },
    [1.1] = {
        Name = 'CAFGridSize',
        ValueConv = function(_self, val) return (val >> 4) .. ' ' .. (val & 0x0f) end, -- (width x height)
        PrintConv = function(_self, val) return (str(val):gsub(' ', 'x')) end,
    },
    [2] = {
        Name = 'CAFPointsInFocus',
        Format = 'int8u[int(($val{1}+3)/4)]',
        Writable = 0,
        PrintConv = function(self, val) return DecodeAFPoints(val, self.NumCAFPoints, 2, 0x02) end,
    },
    [2.1] = {
        Name = 'CAFPointsSelected',
        Format = 'int8u[int(($val{1}+3)/4)]',
        Writable = 0,
        PrintConv = function(self, val) return DecodeAFPoints(val, self.NumCAFPoints, 2, 0x03) end,
    },
}

-- Kelvin white balance information (ref 28, topic 4834)
Pentax.KelvinWB = binaryDataAttrs {
    FORMAT = 'int16u',
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'White balance Blue/Red gains as a function of color temperature.',
    [1]  = kelvinWB { Name = 'KelvinWB_Daylight' },
    [5]  = kelvinWB { Name = 'KelvinWB_01' },
    [9]  = kelvinWB { Name = 'KelvinWB_02' },
    [13] = kelvinWB { Name = 'KelvinWB_03' },
    [17] = kelvinWB { Name = 'KelvinWB_04' },
    [21] = kelvinWB { Name = 'KelvinWB_05' },
    [25] = kelvinWB { Name = 'KelvinWB_06' },
    [29] = kelvinWB { Name = 'KelvinWB_07' },
    [33] = kelvinWB { Name = 'KelvinWB_08' },
    [37] = kelvinWB { Name = 'KelvinWB_09' },
    [41] = kelvinWB { Name = 'KelvinWB_10' },
    [45] = kelvinWB { Name = 'KelvinWB_11' },
    [49] = kelvinWB { Name = 'KelvinWB_12' },
    [53] = kelvinWB { Name = 'KelvinWB_13' },
    [57] = kelvinWB { Name = 'KelvinWB_14' },
    [61] = kelvinWB { Name = 'KelvinWB_15' },
    [65] = kelvinWB { Name = 'KelvinWB_16' },
}

-- color information - PH
Pentax.ColorInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    FORMAT = 'int8s',
    [16] = {
        Name = 'WBShiftAB',
        Notes = 'positive is a shift toward blue',
    },
    [17] = {
        Name = 'WBShiftGM',
        Notes = 'positive is a shift toward green',
    },
}

-- EV step size information - ref 19
Pentax.EVStepInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    [0] = {
        Name = 'EVSteps',
        PrintConv = {
            [0] = '1/2 EV Steps',
            [1] = '1/3 EV Steps',
        },
    },
    [1] = {
        Name = 'SensitivitySteps',
        PrintConv = {
            [0] = '1 EV Steps',
            [1] = 'As EV Steps',
        },
    },
    [3] = { -- #PH
        Name = 'LiveView',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
}

-- shot information? - ref PH (K-5)
Pentax.ShotInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    -- 0: 0xf2/0xf3 (HDR), 0xf0 (otherwise)
    [1] = { -- (presumably this is from an orientation sensor)
        Name = 'CameraOrientation',
        Condition = function(self) return matches(str(self.Model or ''), [==[K-(5|7|r|x)\b]==]) ~= nil end,
        Notes = 'K-5, K-7, K-r and K-x',
        PrintHex = 1,
        PrintConv = {
            [0x10] = 'Horizontal (normal)',
            [0x20] = 'Rotate 180',
            [0x30] = 'Rotate 90 CW',
            [0x40] = 'Rotate 270 CW',
            [0x50] = 'Upwards', -- (to the sky)
            [0x60] = 'Downwards', -- (to the ground)
        },
    },
    -- 2: 0xd3 (live view), 0xdb (HDR), 0x7b (otherwise)
    -- 3: 0xff
    -- 4: 0x64, 0x6a, 0x6f, 0xa4, 0xaa, 0xab, 0xbf
    -- 5: 0xfe
    -- 6: 0x0e
    -- 7: 0x02 (live view), 0x06 (otherwise)
    -- 8-10: 0x00
}

-- face detect positions - ref PH (Optio RZ10)
Pentax.FacePos = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    FORMAT = 'int16u',
    [0] = {
        Name = 'Face1Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 1 then return nil end return val end,
        Notes = 'X/Y coordinates of face center in full-sized image',
    },
    [2] = {
        Name = 'Face2Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 2 then return nil end return val end,
    },
    [4] = {
        Name = 'Face3Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 3 then return nil end return val end,
    },
    [6] = {
        Name = 'Face4Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 4 then return nil end return val end,
    },
    [8] = {
        Name = 'Face5Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 5 then return nil end return val end,
    },
    [10] = {
        Name = 'Face6Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 6 then return nil end return val end,
    },
    [12] = {
        Name = 'Face7Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 7 then return nil end return val end,
    },
    [14] = {
        Name = 'Face8Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 8 then return nil end return val end,
    },
    [16] = {
        Name = 'Face9Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 9 then return nil end return val end,
    },
    [18] = {
        Name = 'Face10Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 10 then return nil end return val end,
    },
    [20] = {
        Name = 'Face11Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 11 then return nil end return val end,
    },
    [22] = {
        Name = 'Face12Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 12 then return nil end return val end,
    },
    [24] = {
        Name = 'Face13Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 13 then return nil end return val end,
    },
    [26] = {
        Name = 'Face14Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 14 then return nil end return val end,
    },
    [28] = {
        Name = 'Face15Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 15 then return nil end return val end,
    },
    [30] = {
        Name = 'Face16Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 16 then return nil end return val end,
    },
    [32] = {
        Name = 'Face17Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 17 then return nil end return val end,
    },
    [34] = {
        Name = 'Face18Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 18 then return nil end return val end,
    },
    [36] = {
        Name = 'Face19Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 19 then return nil end return val end,
    },
    [38] = {
        Name = 'Face20Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 20 then return nil end return val end,
    },
    [40] = {
        Name = 'Face21Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 21 then return nil end return val end,
    },
    [42] = {
        Name = 'Face22Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 22 then return nil end return val end,
    },
    [44] = {
        Name = 'Face23Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 23 then return nil end return val end,
    },
    [46] = {
        Name = 'Face24Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 24 then return nil end return val end,
    },
    [48] = {
        Name = 'Face25Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 25 then return nil end return val end,
    },
    [50] = {
        Name = 'Face26Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 26 then return nil end return val end,
    },
    [52] = {
        Name = 'Face27Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 27 then return nil end return val end,
    },
    [54] = {
        Name = 'Face28Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 28 then return nil end return val end,
    },
    [56] = {
        Name = 'Face29Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 29 then return nil end return val end,
    },
    [58] = {
        Name = 'Face30Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 30 then return nil end return val end,
    },
    [60] = {
        Name = 'Face31Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 31 then return nil end return val end,
    },
    [62] = {
        Name = 'Face32Position',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 32 then return nil end return val end,
    },
}

-- face detect sizes - ref PH (Optio RZ10)
Pentax.FaceSize = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    FORMAT = 'int16u',
    [0] = {
        Name = 'Face1Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 1 then return nil end return val end,
    },
    [2] = {
        Name = 'Face2Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 2 then return nil end return val end,
    },
    [4] = {
        Name = 'Face3Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 3 then return nil end return val end,
    },
    [6] = {
        Name = 'Face4Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 4 then return nil end return val end,
    },
    [8] = {
        Name = 'Face5Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 5 then return nil end return val end,
    },
    [10] = {
        Name = 'Face6Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 6 then return nil end return val end,
    },
    [12] = {
        Name = 'Face7Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 7 then return nil end return val end,
    },
    [14] = {
        Name = 'Face8Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 8 then return nil end return val end,
    },
    [16] = {
        Name = 'Face9Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 9 then return nil end return val end,
    },
    [18] = {
        Name = 'Face10Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 10 then return nil end return val end,
    },
    [20] = {
        Name = 'Face11Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 11 then return nil end return val end,
    },
    [22] = {
        Name = 'Face12Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 12 then return nil end return val end,
    },
    [24] = {
        Name = 'Face13Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 13 then return nil end return val end,
    },
    [26] = {
        Name = 'Face14Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 14 then return nil end return val end,
    },
    [28] = {
        Name = 'Face15Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 15 then return nil end return val end,
    },
    [30] = {
        Name = 'Face16Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 16 then return nil end return val end,
    },
    [32] = {
        Name = 'Face17Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 17 then return nil end return val end,
    },
    [34] = {
        Name = 'Face18Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 18 then return nil end return val end,
    },
    [36] = {
        Name = 'Face19Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 19 then return nil end return val end,
    },
    [38] = {
        Name = 'Face20Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 20 then return nil end return val end,
    },
    [40] = {
        Name = 'Face21Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 21 then return nil end return val end,
    },
    [42] = {
        Name = 'Face22Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 22 then return nil end return val end,
    },
    [44] = {
        Name = 'Face23Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 23 then return nil end return val end,
    },
    [46] = {
        Name = 'Face24Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 24 then return nil end return val end,
    },
    [48] = {
        Name = 'Face25Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 25 then return nil end return val end,
    },
    [50] = {
        Name = 'Face26Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 26 then return nil end return val end,
    },
    [52] = {
        Name = 'Face27Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 27 then return nil end return val end,
    },
    [54] = {
        Name = 'Face28Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 28 then return nil end return val end,
    },
    [56] = {
        Name = 'Face29Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 29 then return nil end return val end,
    },
    [58] = {
        Name = 'Face30Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 30 then return nil end return val end,
    },
    [60] = {
        Name = 'Face31Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 31 then return nil end return val end,
    },
    [62] = {
        Name = 'Face32Size',
        Format = 'int16u[2]',
        RawConv = function(self, val) if perl.num(self.FacesDetected) < 32 then return nil end return val end,
    },
}

-- digital filter information - ref PH (K-5)
Pentax.FilterInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    FORMAT = 'int8u',
    NOTES = [[
        The parameters associated with each type of digital filter are unique, and
        these settings are also extracted with the DigitalFilter tag.  Information
        is not extracted for filters that are "Off" unless the L<Unknown|../ExifTool.html#Unknown> option is
        used.
    ]],
    [0] = {
        Name = 'SourceDirectoryIndex',
        Format = 'int16u',
    },
    [2] = {
        Name = 'SourceFileIndex',
        Format = 'int16u',
    },
    [0x005] = digitalFilter { Name = 'DigitalFilter01' },
    [0x016] = digitalFilter { Name = 'DigitalFilter02' },
    [0x027] = digitalFilter { Name = 'DigitalFilter03' },
    [0x038] = digitalFilter { Name = 'DigitalFilter04' },
    [0x049] = digitalFilter { Name = 'DigitalFilter05' },
    [0x05a] = digitalFilter { Name = 'DigitalFilter06' },
    [0x06b] = digitalFilter { Name = 'DigitalFilter07' },
    [0x07c] = digitalFilter { Name = 'DigitalFilter08' },
    [0x08d] = digitalFilter { Name = 'DigitalFilter09' },
    [0x09e] = digitalFilter { Name = 'DigitalFilter10' },
    [0x0af] = digitalFilter { Name = 'DigitalFilter11' },
    [0x0c0] = digitalFilter { Name = 'DigitalFilter12' },
    [0x0d1] = digitalFilter { Name = 'DigitalFilter13' },
    [0x0e2] = digitalFilter { Name = 'DigitalFilter14' },
    [0x0f3] = digitalFilter { Name = 'DigitalFilter15' },
    [0x104] = digitalFilter { Name = 'DigitalFilter16' },
    [0x115] = digitalFilter { Name = 'DigitalFilter17' },
    [0x126] = digitalFilter { Name = 'DigitalFilter18' },
    [0x137] = digitalFilter { Name = 'DigitalFilter19' },
    [0x148] = digitalFilter { Name = 'DigitalFilter20' },
}

-- electronic level information - ref PH (K-5)
Pentax.LevelInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FORMAT = 'int8s',
    NOTES = [[
        Tags decoded from the electronic level information for the K-5.  May not be
        valid for other models.
    ]],
    [0] = {
        Name = 'LevelOrientation',
        Mask = 0x0f,
        PrintHex = 0,
        PrintConv = {
            [0] = 'n/a', -- #PH (NC, GR III)
            [1] = 'Horizontal (normal)',
            [2] = 'Rotate 180',
            [3] = 'Rotate 90 CW',
            [4] = 'Rotate 270 CW',
            [9] = 'Horizontal; Off Level',
            [10] = 'Rotate 180; Off Level',
            [11] = 'Rotate 90 CW; Off Level',
            [12] = 'Rotate 270 CW; Off Level',
            [13] = 'Upwards',
            [14] = 'Downwards',
        },
    },
    [0.1] = {
        Name = 'CompositionAdjust',
        Mask = 0xf0,
        PrintConv = {
            [0] = 'Off',
            [2] = 'Composition Adjust',
            [10] = 'Composition Adjust + Horizon Correction',
            [12] = 'Horizon Correction',
        },
    },
    [1] = {
        Name = 'RollAngle',
        Notes = 'converted to degrees of clockwise camera rotation',
        ValueConv = function(_self, val) return -val / 2 end,
        ValueConvInv = function(_self, val) return -val * 2 end,
    },
    [2] = {
        Name = 'PitchAngle',
        Notes = 'converted to degrees of upward camera tilt',
        ValueConv = function(_self, val) return -val / 2 end,
        ValueConvInv = function(_self, val) return -val * 2 end,
    },
    -- 3,4 - related somehow to horizon correction and composition adjust
    -- 5,6,7 - (the notes below refer to how the image moves in the LCD monitor)
    [5] = {
        Name = 'CompositionAdjustX',
        Notes = 'steps to the right, 1/16 mm per step',
        ValueConv = function(_self, val) return -val end,
        ValueConvInv = function(_self, val) return -val end,
    },
    [6] = {
        Name = 'CompositionAdjustY',
        Notes = 'steps up, 1/16 mm per step',
        ValueConv = function(_self, val) return -val end,
        ValueConvInv = function(_self, val) return -val end,
    },
    [7] = {
        Name = 'CompositionAdjustRotation',
        Notes = 'steps clockwise, 1/8 degree per step',
        ValueConv = function(_self, val) return -val / 2 end,
        ValueConvInv = function(_self, val) return -val * 2 end,
    },
}

Pentax.LevelInfoK3III = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FORMAT = 'int8s',
    NOTES = 'Tags decoded from the electronic level information for the K-3 III.',
    [1] = {
        Name = 'CameraOrientation',
        PrintConv = {
            [0] = 'Horizontal (normal)',
            [1] = 'Rotate 270 CW',
            [2] = 'Rotate 180',
            [3] = 'Rotate 90 CW',
            [4] = 'Upwards', -- (to the sky)
            [5] = 'Downwards', -- (to the ground)
        },
    },
    [3] = {
        Name = 'RollAngle',
        Notes = 'converted to degrees of clockwise camera rotation',
        Format = 'int16s',
        ValueConv = function(_self, val) return -val / 2 end,
        ValueConvInv = function(_self, val) return -val * 2 end,
    },
    [5] = {
        Name = 'PitchAngle',
        Notes = 'converted to degrees of upward camera tilt',
        Format = 'int16s',
        ValueConv = function(_self, val) return -val / 2 end,
        ValueConvInv = function(_self, val) return -val * 2 end,
    },
}

Pentax.FaceInfoK3III = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Image' },
    FORMAT = 'int32u',
    DATAMEMBER = { 6, 8 },
    [0.1] = {
        Name = 'FaceInfoK3III',
        Format = 'int32u[$size/4]',
        Notes = [[
            entire FaceInfoK3III structure. Provides access to raw numerical values and
            facilitates the writing of the whole structure
        ]],
        Unknown = 1,
    },
    [0] = { Name = 'FaceImageSize', Format = 'int32u[2]' },
    [2] = { Name = 'CAFArea', Format = 'int32u[4]', Notes = 'top, left, width, height' },
    [6] = { Name = 'FacesDetectedA', RawConv = function(self, val) self.FacesA = val; return val end },
    [8] = { Name = 'FacesDetectedB', RawConv = function(self, val) self.FacesA = val; return val end },
    [10] = { Name = 'Face1AArea', Condition = function(self) return perl.num(self.FacesA) >= 1 end, Format = 'int32u[4]' },
    [14] = { Name = 'Face1AEye1', Condition = function(self) return perl.num(self.FacesA) >= 1 end, Format = 'int32u[4]' },
    [18] = { Name = 'Face1AEye2', Condition = function(self) return perl.num(self.FacesA) >= 1 end, Format = 'int32u[4]' },
    [30] = { Name = 'Face2AArea', Condition = function(self) return perl.num(self.FacesA) >= 2 end, Format = 'int32u[4]' },
    [34] = { Name = 'Face2AEye1', Condition = function(self) return perl.num(self.FacesA) >= 2 end, Format = 'int32u[4]' },
    [38] = { Name = 'Face2AEye2', Condition = function(self) return perl.num(self.FacesA) >= 2 end, Format = 'int32u[4]' },
    [50] = { Name = 'Face3AArea', Condition = function(self) return perl.num(self.FacesA) >= 3 end, Format = 'int32u[4]' },
    [54] = { Name = 'Face3AEye1', Condition = function(self) return perl.num(self.FacesA) >= 3 end, Format = 'int32u[4]' },
    [58] = { Name = 'Face3AEye2', Condition = function(self) return perl.num(self.FacesA) >= 3 end, Format = 'int32u[4]' },
    [70] = { Name = 'Face4AArea', Condition = function(self) return perl.num(self.FacesA) >= 4 end, Format = 'int32u[4]' },
    [74] = { Name = 'Face4AEye1', Condition = function(self) return perl.num(self.FacesA) >= 4 end, Format = 'int32u[4]' },
    [78] = { Name = 'Face4AEye2', Condition = function(self) return perl.num(self.FacesA) >= 4 end, Format = 'int32u[4]' },
    [90] = { Name = 'Face5AArea', Condition = function(self) return perl.num(self.FacesA) >= 5 end, Format = 'int32u[4]' },
    [94] = { Name = 'Face5AEye1', Condition = function(self) return perl.num(self.FacesA) >= 5 end, Format = 'int32u[4]' },
    [98] = { Name = 'Face5AEye2', Condition = function(self) return perl.num(self.FacesA) >= 5 end, Format = 'int32u[4]' },
    [110] = { Name = 'Face6AArea', Condition = function(self) return perl.num(self.FacesA) >= 6 end, Format = 'int32u[4]' },
    [114] = { Name = 'Face6AEye1', Condition = function(self) return perl.num(self.FacesA) >= 6 end, Format = 'int32u[4]' },
    [118] = { Name = 'Face6AEye2', Condition = function(self) return perl.num(self.FacesA) >= 6 end, Format = 'int32u[4]' },
    [130] = { Name = 'Face7AArea', Condition = function(self) return perl.num(self.FacesA) >= 7 end, Format = 'int32u[4]' },
    [134] = { Name = 'Face7AEye1', Condition = function(self) return perl.num(self.FacesA) >= 7 end, Format = 'int32u[4]' },
    [138] = { Name = 'Face7AEye2', Condition = function(self) return perl.num(self.FacesA) >= 7 end, Format = 'int32u[4]' },
    [150] = { Name = 'Face8AArea', Condition = function(self) return perl.num(self.FacesA) >= 8 end, Format = 'int32u[4]' },
    [154] = { Name = 'Face8AEye1', Condition = function(self) return perl.num(self.FacesA) >= 8 end, Format = 'int32u[4]' },
    [158] = { Name = 'Face8AEye2', Condition = function(self) return perl.num(self.FacesA) >= 8 end, Format = 'int32u[4]' },
    [170] = { Name = 'Face9AArea', Condition = function(self) return perl.num(self.FacesA) >= 9 end, Format = 'int32u[4]' },
    [174] = { Name = 'Face9AEye1', Condition = function(self) return perl.num(self.FacesA) >= 9 end, Format = 'int32u[4]' },
    [178] = { Name = 'Face9AEye2', Condition = function(self) return perl.num(self.FacesA) >= 9 end, Format = 'int32u[4]' },
    [190] = { Name = 'Face10AArea',Condition = function(self) return perl.num(self.FacesA) >= 10 end, Format = 'int32u[4]' },
    [194] = { Name = 'Face10AEye1',Condition = function(self) return perl.num(self.FacesA) >= 10 end, Format = 'int32u[4]' },
    [198] = { Name = 'Face10AEye2',Condition = function(self) return perl.num(self.FacesA) >= 10 end, Format = 'int32u[4]' },
    [210] = { Name = 'Face1BArea', Condition = function(self) return perl.num(self.FacesA) >= 1 end, Format = 'int32u[4]' },
    [214] = { Name = 'Face1BEye1', Condition = function(self) return perl.num(self.FacesA) >= 1 end, Format = 'int32u[4]' },
    [218] = { Name = 'Face1BEye2', Condition = function(self) return perl.num(self.FacesA) >= 1 end, Format = 'int32u[4]' },
    [230] = { Name = 'Face2BArea', Condition = function(self) return perl.num(self.FacesA) >= 2 end, Format = 'int32u[4]' },
    [234] = { Name = 'Face2BEye1', Condition = function(self) return perl.num(self.FacesA) >= 2 end, Format = 'int32u[4]' },
    [238] = { Name = 'Face2BEye2', Condition = function(self) return perl.num(self.FacesA) >= 2 end, Format = 'int32u[4]' },
    [250] = { Name = 'Face3BArea', Condition = function(self) return perl.num(self.FacesA) >= 3 end, Format = 'int32u[4]' },
    [254] = { Name = 'Face3BEye1', Condition = function(self) return perl.num(self.FacesA) >= 3 end, Format = 'int32u[4]' },
    [258] = { Name = 'Face3BEye2', Condition = function(self) return perl.num(self.FacesA) >= 3 end, Format = 'int32u[4]' },
    [270] = { Name = 'Face4BArea', Condition = function(self) return perl.num(self.FacesA) >= 4 end, Format = 'int32u[4]' },
    [274] = { Name = 'Face4BEye1', Condition = function(self) return perl.num(self.FacesA) >= 4 end, Format = 'int32u[4]' },
    [278] = { Name = 'Face4BEye2', Condition = function(self) return perl.num(self.FacesA) >= 4 end, Format = 'int32u[4]' },
    [290] = { Name = 'Face5BArea', Condition = function(self) return perl.num(self.FacesA) >= 5 end, Format = 'int32u[4]' },
    [294] = { Name = 'Face5BEye1', Condition = function(self) return perl.num(self.FacesA) >= 5 end, Format = 'int32u[4]' },
    [298] = { Name = 'Face5BEye2', Condition = function(self) return perl.num(self.FacesA) >= 5 end, Format = 'int32u[4]' },
    [310] = { Name = 'Face6BArea', Condition = function(self) return perl.num(self.FacesA) >= 6 end, Format = 'int32u[4]' },
    [314] = { Name = 'Face6BEye1', Condition = function(self) return perl.num(self.FacesA) >= 6 end, Format = 'int32u[4]' },
    [318] = { Name = 'Face6BEye2', Condition = function(self) return perl.num(self.FacesA) >= 6 end, Format = 'int32u[4]' },
    [330] = { Name = 'Face7BArea', Condition = function(self) return perl.num(self.FacesA) >= 7 end, Format = 'int32u[4]' },
    [334] = { Name = 'Face7BEye1', Condition = function(self) return perl.num(self.FacesA) >= 7 end, Format = 'int32u[4]' },
    [338] = { Name = 'Face7BEye2', Condition = function(self) return perl.num(self.FacesA) >= 7 end, Format = 'int32u[4]' },
    [350] = { Name = 'Face8BArea', Condition = function(self) return perl.num(self.FacesA) >= 8 end, Format = 'int32u[4]' },
    [354] = { Name = 'Face8BEye1', Condition = function(self) return perl.num(self.FacesA) >= 8 end, Format = 'int32u[4]' },
    [358] = { Name = 'Face8BEye2', Condition = function(self) return perl.num(self.FacesA) >= 8 end, Format = 'int32u[4]' },
    [370] = { Name = 'Face9BArea', Condition = function(self) return perl.num(self.FacesA) >= 9 end, Format = 'int32u[4]' },
    [374] = { Name = 'Face9BEye1', Condition = function(self) return perl.num(self.FacesA) >= 9 end, Format = 'int32u[4]' },
    [378] = { Name = 'Face9BEye2', Condition = function(self) return perl.num(self.FacesA) >= 9 end, Format = 'int32u[4]' },
    [390] = { Name = 'Face10BArea',Condition = function(self) return perl.num(self.FacesA) >= 10 end, Format = 'int32u[4]' },
    [394] = { Name = 'Face10BEye1',Condition = function(self) return perl.num(self.FacesA) >= 10 end, Format = 'int32u[4]' },
    [398] = { Name = 'Face10BEye2',Condition = function(self) return perl.num(self.FacesA) >= 10 end, Format = 'int32u[4]' },
}

Pentax.AFInfoK3III = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FORMAT = 'int16u',
    DATAMEMBER = { 2, 3 },
    NOTES = 'AF tags written by the K-3 Mark III, GR III, GR IIIx and GR IV.',
    [0] = {
        Name = 'AFInfoK3III',
        Format = 'int16u[$size/2]',
        Notes = [[
            entire AFInfoK3III structure. Provides access to raw numerical values and
            facilitates the writing of the whole structure
        ]],
        Unknown = 1,
    },
    [0.1] = {
        Name = 'AFMode',
        PrintConv = {
            [0] = 'Phase Detect',
            [2] = 'Contrast Detect',
            [255] = 'Manual Focus',
        },
    },
    [1] = {
        Name = 'AFSelectionMode',
        PrintHex = 1,
        PrintConv = {
            [0] = 'Manual Focus',
            [1] = 'Spot',
            [2] = 'Select (5-points)',
            [3] = 'Expanded Area (S)',
            [4] = 'Expanded Area (M)',
            [5] = 'Expanded Area (L)',
            [6] = 'Select (S)',
            [7] = 'Zone Select (21-point)',
            [8] = 'Select XS',
            [0xff] = 'Auto Area',
            -- Contrast-detect modes
            [0x2001] = 'Contrast-detect Auto Area',
            [0x2002] = 'Contrast-detect Select', -- (GR III)
            [0x2003] = 'Pinpoint', -- (GR III)
            [0x2004] = 'Tracking',
            [0x2005] = 'Continuous', -- (GR III)
            [0x2006] = 'Face Detection',
            [0x2007] = 'Contrast-detect Select (S)',
            [0x2008] = 'Contrast-detect Select (M)',
            [0x2009] = 'Contrast-detect Select (L)',
            [0x200a] = 'Contrast-detect Zone Select', -- (GR III)
            [0x200b] = 'Contrast-detect Spot',
        },
    },
    [2] = {
        Name = 'MaxNumAFPoints',
        RawConv = function(self, val) self.MaxNumAFPoints = val; return val end,
    },
    [3] = {
        Name = 'NumAFPoints',
        RawConv = function(self, val) self.NumAFPoints = val; return val end,
    },
    -- the data for each AF point consists of 7 int16u values:
    -- the frame width/height, the X/Y position of the focus area,
    -- width/height of the focus area (0/0 for phase-detect modes),
    -- followed by a flags word
    [7] = { -- (the same for all areas in my samples, so only extract the first)
        Name = 'AFFrameSize',
        Condition = function(self) return self.NumAFPoints > 0 end,
        Format = 'int16u[2]',
        Writable = 0,
        PrintConv = function(_self, val) return (str(val):gsub(' ', 'x')) end,
    },
    [7.1] = {
        Name = 'AFAreas',
        Format = 'int16u[7 * $val{3}]',
        Notes = [[
            X,Y position of each AF area, width, with "in-focus" for points in focus,
            "central" for the center of the selected area, or "peripheral" for points
            outside the selected area
        ]],
        Writable = 0,
        List = 1, -- (for documentation purposes only)
        PrintConv = function(self, val) return AFAreasK3III(val, self) end,
    },
    [11] = { -- (the same for all areas in my samples, so only extract the first)
        Name = 'AFAreaSize',
        Condition = function(self, val)
            return self.NumAFPoints > 0 and matches(str(val), [==[^\0\0\0\0]==]) == nil
        end,
        Notes = 'only for contrast-detect modes',
        Format = 'int16u[2]',
        Writable = 0,
        PrintConv = function(_self, val) return (str(val):gsub(' ', 'x')) end,
    },
}

-- white balance RGGB levels (ref 28)
Pentax.WBLevels = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    -- 0 - 11 (number of entries in this table)
    -- 1 - 0
    [2] = {
        Name = 'WB_RGGBLevelsDaylight',
        Format = 'int16u[4]',
    },
    -- 10 - 1
    [11] = {
        Name = 'WB_RGGBLevelsShade',
        Format = 'int16u[4]',
    },
    -- 19 - 2
    [20] = {
        Name = 'WB_RGGBLevelsCloudy',
        Format = 'int16u[4]',
    },
    -- 28 - 3
    [29] = {
        Name = 'WB_RGGBLevelsTungsten',
        Format = 'int16u[4]',
    },
    -- 37 - 4
    [38] = {
        Name = 'WB_RGGBLevelsFluorescentD',
        Format = 'int16u[4]',
    },
    -- 46 - 5
    [47] = {
        Name = 'WB_RGGBLevelsFluorescentN',
        Format = 'int16u[4]',
    },
    -- 55 - 6
    [56] = {
        Name = 'WB_RGGBLevelsFluorescentW',
        Format = 'int16u[4]',
    },
    -- 64 - 7
    [65] = {
        Name = 'WB_RGGBLevelsFlash',
        Format = 'int16u[4]',
    },
    -- 73 - 8
    [74] = {
        Name = 'WB_RGGBLevelsFluorescentL',
        Format = 'int16u[4]',
    },
    -- 82 - 0xfe
    [83] = {
        Name = 'WB_RGGBLevelsUnknown',
        Format = 'int16u[4]',
        Unknown = 1,
    },
    -- 91 - 0xff
    [92] = {
        Name = 'WB_RGGBLevelsUserSelected',
        Format = 'int16u[4]',
    },
}

-- lens information for Pentax Q (ref PH)
-- (306 bytes long, I wonder if this contains vignetting information too?)
Pentax.LensInfoQ = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'More lens information stored by the Pentax Q.',
    [0x0c] = {
        Name = 'LensModel',
        Format = 'string[30]',
    },
    [0x2a] = {
        Name = 'LensInfo',
        Format = 'string[20]',
        ValueConv = function(_self, val) return (str(val):gsub('mm', 'mm ', 1)) end,
        ValueConvInv = function(_self, val) return (str(val):gsub(' ', '')) end,
    }
}

-- Pixel shift information for the K-3II (ref PH)
Pentax.PixelShiftInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'Pixel shift information stored by the K-3 II.',
    [0x00] = {
        Name = 'PixelShiftResolution',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
}

-- AF point information for the K-1 (ref 29)
Pentax.AFPointInfo = binaryDataAttrs {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    DATAMEMBER = { 2 },
    NOTES = 'AF point information written by the K-1.',
    -- 0 - int16u: 1 (version?)
    [2] = {
        Name = 'NumAFPoints',
        Format = 'int16u',
        RawConv = function(self, val) self.NumAFPoints = val; return val end,
    },
    [4] = {
        Name = 'AFPointsInFocus',
        Condition = function(self) return matches(str(self.Model or ''), [==[K(P|-1|-70)\b]==]) ~= nil end,
        Format = 'int8u[int(($val{2}+3)/4)]',
        Writable = 0,
        PrintConv = function(self, val) return DecodeAFPoints(val, self.NumAFPoints, 2, 0x02) end,
    },
    [4.1] = {
        Name = 'AFPointsSelected',
        Condition = function(self) return matches(str(self.Model or ''), [==[K(P|-1|-70)\b]==]) ~= nil end,
        Format = 'int8u[int(($val{2}+3)/4)]',
        Writable = 0,
        PrintConv = function(self, val) return DecodeAFPoints(val, self.NumAFPoints, 2, 0x03) end,
    },
    [4.2] = {
        Name = 'AFPointsSpecial',
        Condition = function(self) return matches(str(self.Model or ''), [==[K(P|-1|-70)\b]==]) ~= nil end,
        Format = 'int8u[int(($val{2}+3)/4)]',
        Writable = 0,
        PrintConv = function(self, val) return DecodeAFPoints(val, self.NumAFPoints, 2, 0x03, 0x03) end,
    },
}

-- Pentax metadata in MOV videos (PH) (upstream %Pentax::MOV)
-- ASCII-based maker notes of Optio 330 and 430 (similar to Casio)
Pentax.Type2 = {
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    WRITABLE = 'int16u',
    NOTES = [[
        These tags are used by the Pentax Optio 330 and 430, and are similar to the
        tags used by Casio.
    ]],
    [0x0001] = {
        Name = 'RecordingMode',
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Night Scene',
            [2] = 'Manual',
        },
    },
    [0x0002] = {
        Name = 'Quality',
        PrintConv = {
            [0] = 'Good',
            [1] = 'Better',
            [2] = 'Best',
        },
    },
    [0x0003] = {
        Name = 'FocusMode',
        PrintConv = {
            [2] = 'Custom',
            [3] = 'Auto',
        },
    },
    [0x0004] = {
        Name = 'FlashMode',
        PrintConv = {
            [1] = 'Auto',
            [2] = 'On',
            [4] = 'Off',
            [6] = 'Red-eye reduction',
        },
    },
    -- Casio 0x0005 is FlashIntensity
    -- Casio 0x0006 is ObjectDistance
    [0x0007] = {
        Name = 'WhiteBalance',
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Daylight',
            [2] = 'Shade',
            [3] = 'Tungsten',
            [4] = 'Fluorescent',
            [5] = 'Manual',
        },
    },
    [0x000a] = {
        Name = 'DigitalZoom',
        Writable = 'int32u',
    },
    [0x000b] = {
        Name = 'Sharpness',
        PrintConv = {
            [0] = 'Normal',
            [1] = 'Soft',
            [2] = 'Hard',
        },
    },
    [0x000c] = {
        Name = 'Contrast',
        PrintConv = {
            [0] = 'Normal',
            [1] = 'Low',
            [2] = 'High',
        },
    },
    [0x000d] = {
        Name = 'Saturation',
        PrintConv = {
            [0] = 'Normal',
            [1] = 'Low',
            [2] = 'High',
        },
    },
    [0x0014] = {
        Name = 'ISO',
        Priority = 0,
        PrintConv = {
            [10] = 100,
            [16] = 200,
            [50] = 50, -- #PH
            [100] = 100, -- #PH
            [200] = 200, -- #PH
            [400] = 400, -- #PH
            [800] = 800, -- #PH
            [1600] = 1600, -- #PH
            [3200] = 3200, -- #PH
            [65534] = 'Auto 2', -- #PH (Q-S1 MOV) [how is this different from 65535?]
            [65535] = 'Auto', -- #PH (K-S1 MOV)
        },
    },
    [0x0017] = {
        Name = 'ColorFilter',
        PrintConv = {
            [1] = 'Full',
            [2] = 'Black & White',
            [3] = 'Sepia',
        },
    },
    -- Casio 0x0018 is AFPoint
    -- Casio 0x0019 is FlashIntensity
    [0x0e00] = {
        Name = 'PrintIM',
        Description = 'Print Image Matching',
        Writable = 0,
        SubDirectory = {
            TagTable = 'lexiftool.PrintIM.Main',
        },
    },
    [0x1000] = {
        Name = 'HometownCityCode',
        Writable = 'undef',
        Count = 4,
    },
    [0x1001] = { -- #PH
        Name = 'DestinationCityCode',
        Writable = 'undef',
        Count = 4,
    },
}

-- ASCII-based maker notes of Optio E20 and E25 - PH
Pentax.Type4 = {
    PROCESS_PROC = HP.ProcessHP,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = [[
        The following few tags are extracted from the wealth of information
        available in maker notes of the Optio E20 and E25.  These maker notes are
        stored as ASCII text in a format very similar to some HP models.
    ]],
    ['F/W Version'] = 'FirmwareVersion',
}

Pentax.MOV = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FIRST_ENTRY = 0,
    NOTES = 'This information is found in MOV videos from cameras such as the Optio WP.',
    [0x00] = {
        Name = 'Make',
        Format = 'string[24]',
    },
    -- (01 00 at offset 0x20)
    [0x26] = {
        Name = 'ExposureTime',
        Format = 'int32u',
        ValueConv = function(_self, val) return ExifTool.perlTruthy(val) and (10 / val) or 0 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    [0x2a] = {
        Name = 'FNumber',
        Format = 'rational64u',
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
    },
    [0x32] = {
        Name = 'ExposureCompensation',
        Format = 'rational64s',
        -- (Perl truthiness: the raw value arrives as the string '0' here,
        --  which is false in Perl but true in Lua)
        PrintConv = function(_self, val)
            if not ExifTool.perlTruthy(val) then return 0 end
            return sprintf('%+.1f', val)
        end,
    },
    [0x44] = {
        Name = 'WhiteBalance',
        Format = 'int16u',
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Daylight',
            [2] = 'Shade',
            [3] = 'Fluorescent', --2
            [4] = 'Tungsten',
            [5] = 'Manual',
        },
    },
    [0x48] = {
        Name = 'FocalLength',
        Format = 'rational64u',
        PrintConv = function(_self, val) return sprintf('%.1f mm', val) end,
    },
    [0xaf] = {
        Name = 'ISO',
        Format = 'int16u',
    },
}

-- Pentax-specific RIFF tags found in AVI videos (upstream %Pentax::AVI)
Pentax.AVI = {
    NOTES = 'Pentax-specific RIFF tags found in AVI videos.',
    GROUPS = { [0] = 'MakerNotes', [2] = 'Video' },
    hymn = {
        Name = 'MakerNotes',
        SubDirectory = {
            TagTable = 'lexiftool.Pentax.Main',
            Start = 10,
            Base = function(_et, _val, start) return start end,
            ByteOrder = 'Unknown', -- K-70 is little-endian, K-x is big-endian
        },
    },
    mknt = { -- (Q-S1)
        Name = 'MakerNotes',
        SubDirectory = {
            TagTable = 'lexiftool.Pentax.Main',
            Start = 10,
            Base = function(_et, _val, start) return start end,
            ByteOrder = 'Unknown',
        },
    },
}

-- Pentax metadata in AVI videos from the Optio S1 (PH)
Pentax.S1 = {
    NOTES = 'Tags extracted from the maker notes of AVI videos from the Optio S1.',
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    [0x0000] = { -- #5
        Name = 'MakerNoteVersion',
        Writable = 'undef',
        Count = 4,
    },
}

-- Pentax metadata in AVI videos from the RS1000 (PH)
Pentax.Junk = {
    NOTES = 'Tags found in the JUNK chunk of AVI videos from the RS1000.',
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    [0x0c] = {
        Name = 'Model',
        Description = 'Camera Model Name',
        Format = 'string[32]',
    },
}

-- PreviewImage information found in PXTH atom of K-01 MOV videos
Pentax.PXTH = {
    NOTES = 'Tags found in the PXTH atom of MOV videos from the K-01.',
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    [0x00] = {
        Name = 'PreviewImageLength',
        Format = 'int32u',
    },
    [0x04] = {
        Name = 'PreviewImage',
        Groups = { [2] = 'Preview' },
        Format = 'undef[$val{0}]',
        Notes = '640-pixel-wide JPEG preview', -- (360 pixels high, may depend on aspect ratio)
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage returns the image reference; the port's returns the data)
            local pt = self:ValidateImage(val, tag)
            if pt == nil then return nil end
            return { ref = 'SCALAR', value = pt }
        end,
    },
}

-- information in PENT atom of MOV videos from the Optio WG-2 GPS
Pentax.PENT = {
    NOTES = 'Tags found in the PENT atom of MOV videos from the Optio WG-2 GPS.',
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    [0] = {
        Name = 'Make',
        Format = 'string[24]',
    },
    [0x1a] = {
        Name = 'Model',
        Description = 'Camera Model Name',
        Format = 'string[24]',
    },
    [0x38] = { --(NC)
        Name = 'ExposureTime',
        Format = 'int32u',
        ValueConv = function(_self, val) return ExifTool.perlTruthy(val) and (10 / val) or 0 end,
        PrintConv = function(_self, val) return Exif.PrintExposureTime(val) end,
    },
    [0x3c] = {
        Name = 'FNumber',
        Format = 'rational64u',
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
    },
    [0x44] = { --(NC)
        Name = 'ExposureCompensation',
        Format = 'rational64s',
        PrintConv = function(_self, val) return ExifTool.perlTruthy(val) and sprintf('%+.1f', val) or 0 end,
    },
    [0x54] = { --(NC)
        Name = 'FocalLength',
        Format = 'int32u',
        PrintConv = function(_self, val) return str(val) .. ' mm' end,
    },
    [0x71] = {
        Name = 'DateTime1',
        Format = 'string[24]',
        Groups = { [2] = 'Time' },
    },
    [0x8b] = {
        Name = 'DateTime2',
        Format = 'string[24]',
        Groups = { [2] = 'Time' },
    },
    [0xa7] = { --(NC)
        Name = 'ISO',
        Format = 'int32u',
    },
    [0xc7] = {
        Name = 'GPSVersionID',
        Format = 'undef[8]',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        DataMember = 'GPSVersionID',
        RawConv = function(self, val)
            local s, n = str(val):gsub('GPS_', '')
            if n == 0 then self.GPSVersionID = nil; return nil end
            local out = {}
            for i = 1, #s do out[#out + 1] = str(s:byte(i)) end
            self.GPSVersionID = table.concat(out, ' ')
            return self.GPSVersionID
        end,
        PrintConv = function(_self, val) return (str(val):gsub(' ', '.')) end,
    },
    [0xcf] = {
        Name = 'GPSLatitudeRef',
        Condition = function(self) return ExifTool.perlTruthy(self.GPSVersionID) end,
        Format = 'string[2]',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = {
            N = 'North',
            S = 'South',
        },
    },
    [0xd1] = {
        Name = 'GPSLatitude',
        Condition = function(self) return ExifTool.perlTruthy(self.GPSVersionID) end,
        Format = 'rational64u[3]',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        ValueConv    = function(_self, val) return GPS.ToDegrees(val) end,
        PrintConv    = function(self, val) return GPS.ToDMS(self, val, 1) end,
    },
    [0xe9] = {
        Name = 'GPSLongitudeRef',
        Condition = function(self) return ExifTool.perlTruthy(self.GPSVersionID) end,
        Format = 'string[2]',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = {
            E = 'East',
            W = 'West',
        },
    },
    [0xeb] = {
        Name = 'GPSLongitude',
        Condition = function(self) return ExifTool.perlTruthy(self.GPSVersionID) end,
        Format = 'rational64u[3]',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        ValueConv    = function(_self, val) return GPS.ToDegrees(val) end,
        PrintConv    = function(self, val) return GPS.ToDMS(self, val, 1) end,
    },
    [0x103] = {
        Name = 'GPSAltitudeRef',
        Condition = function(self) return ExifTool.perlTruthy(self.GPSVersionID) end,
        Format = 'int8u',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = {
            [0] = 'Above Sea Level',
            [1] = 'Below Sea Level',
        },
    },
    [0x104] = {
        Name = 'GPSAltitude',
        Condition = function(self) return ExifTool.perlTruthy(self.GPSVersionID) end,
        Format = 'rational64u',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = function(_self, val)
            val = str(val)
            return matches(val, [==[^(inf|undef)$]==]) and val or (val .. ' m')
        end,
    },
    [0x11c] = {
        Name = 'GPSTimeStamp',
        Condition = function(self) return ExifTool.perlTruthy(self.GPSVersionID) end,
        Groups = { [1] = 'GPS', [2] = 'Time' },
        Format = 'rational64u[3]',
        ValueConv = function(_self, val) return GPS.ConvertTimeStamp(val) end,
        PrintConv = function(_self, val) return GPS.PrintTimeStamp(val) end,
    },
    [0x134] = {
        Name = 'GPSSatellites',
        Condition = function(self) return ExifTool.perlTruthy(self.GPSVersionID) end,
        Format = 'string[3]',
        Groups = { [1] = 'GPS', [2] = 'Location' },
    },
    [0x137] = {
        Name = 'GPSStatus',
        Condition = function(self) return ExifTool.perlTruthy(self.GPSVersionID) end,
        Format = 'string[2]',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = {
            A = 'Measurement Active',
            V = 'Measurement Void',
        },
    },
    [0x139] = {
        Name = 'GPSMeasureMode',
        Condition = function(self) return ExifTool.perlTruthy(self.GPSVersionID) end,
        Format = 'string[2]',
        Groups = { [1] = 'GPS', [2] = 'Location' },
        PrintConv = {
            [2] = '2-Dimensional Measurement',
            [3] = '3-Dimensional Measurement',
        },
    },
    [0x13b] = {
        Name = 'GPSMapDatum',
        Condition = function(self) return ExifTool.perlTruthy(self.GPSVersionID) end,
        Format = 'string[7]',
        Groups = { [1] = 'GPS', [2] = 'Location' },
    },
    [0x142] = {
        Name = 'GPSDateStamp',
        Condition = function(self) return ExifTool.perlTruthy(self.GPSVersionID) end,
        Groups = { [1] = 'GPS', [2] = 'Time' },
        Format = 'string[11]',
        -- upstream calls Image::ExifTool::Exif::ExifDate; the port keeps that
        -- routine in GPS.lua (GPS.ExifDate), a verbatim port of the same sub
        ValueConv = function(_self, val) return GPS.ExifDate(val) end,
    },
    [0x173] = { --(NC)
        Name = 'AudioCodecID',
        Format = 'string[4]',
    },
    [0x7d3] = {
        Name = 'PreviewImage',
        Groups = { [2] = 'Preview' },
        Format = 'undef[$size-0x7d3]',
        Notes = '640x480 JPEG preview image', -- (black borders pad to 480 pixels high)
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage returns the image reference; the port's returns the data)
            local pt = self:ValidateImage(val, tag)
            if pt == nil then return nil end
            return { ref = 'SCALAR', value = pt }
        end,
    },
}

-- tags in Pentax Optio RZ18 AVI videos (ref PH)
-- (very similar to Olympus::AVI tags)
Pentax.Junk2 = {
    PROCESS_PROC = ExifTool.ProcessBinaryData,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    FIRST_ENTRY = 0,
    NOTES = 'This information is found in AVI videos from the Optio RZ18.',
    [0x12] = {
        Name = 'Make',
        Format = 'string[24]',
    },
    [0x2c] = {
        Name = 'Model',
        Description = 'Camera Model Name',
        Format = 'string[24]',
    },
    [0x5e] = {
        Name = 'FNumber',
        Format = 'rational64u',
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
    },
    [0x83] = {
        Name = 'DateTime1',
        Format = 'string[24]',
        Groups = { [2] = 'Time' },
    },
    [0x9d] = {
        Name = 'DateTime2',
        Format = 'string[24]',
        Groups = { [2] = 'Time' },
    },
    [0x12b] = {
        Name = 'ThumbnailWidth',
        Format = 'int16u',
    },
    [0x12d] = {
        Name = 'ThumbnailHeight',
        Format = 'int16u',
    },
    [0x12f] = {
        Name = 'ThumbnailLength',
        Format = 'int32u',
    },
    [0x133] = {
        Name = 'ThumbnailImage',
        Groups = { [2] = 'Preview' },
        Format = 'undef[$val{0x12f}]',
        Notes = '160x120 JPEG thumbnail image',
        RawConv = function(self, val, tag)
            -- (upstream ValidateImage returns the image reference; the port's returns the data)
            local pt = self:ValidateImage(val, tag)
            if pt == nil then return nil end
            return { ref = 'SCALAR', value = pt }
        end,
    },
}

return Pentax
