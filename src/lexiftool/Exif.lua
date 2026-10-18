--------------------------------------------------------------------------------
-- File:         lexiftool/Exif.lua
-- Ported from:  lib/Image/ExifTool/Exif.pm
--
-- Description:  Read EXIF/TIFF meta information
--
-- Revisions:    11/25/2003 - P. Harvey Created
--               02/06/2004 - P. Harvey Moved processing functions from ExifTool
--               03/19/2004 - P. Harvey Check PreviewImage for validity
--               11/11/2004 - P. Harvey Split off maker notes into MakerNotes.pm
--               12/13/2004 - P. Harvey Added AUTOLOAD to load write routines
--
-- References:   0) http://www.exif.org/Exif2-2.PDF
--               1) http://partners.adobe.com/asn/developer/pdfs/tn/TIFF6.pdf
--               2) http://www.adobe.com/products/dng/pdfs/dng_spec_1_3_0_0.pdf
--               3) http://www.awaresystems.be/imaging/tiff/tifftags.html
--               4) http://www.remotesensing.org/libtiff/TIFFTechNote2.html
--               5) http://www.exif.org/dcf.PDF
--               6) http://park2.wakwak.com/~tsuruzoh/Computer/Digicams/exif-e.html
--               7) http://www.fine-view.com/jp/lab/doc/ps6ffspecsv2.pdf
--               8) http://www.ozhiker.com/electronics/pjmt/jpeg_info/meta.html
--               9) http://hul.harvard.edu/jhove/tiff-tags.html
--              10) http://partners.adobe.com/public/developer/en/tiff/TIFFPM6.pdf
--              11) Robert Mucke private communication
--              12) http://www.broomscloset.com/closet/photo/exif/TAG2000-22_DIS12234-2.PDF
--              13) http://www.microsoft.com/whdc/xps/wmphoto.mspx
--              14) http://www.asmail.be/msg0054681802.html
--              15) http://crousseau.free.fr/imgfmt_raw.htm
--              16) http://www.cybercom.net/~dcoffin/dcraw/
--              17) http://www.digitalpreservation.gov/formats/content/tiff_tags.shtml
--              18) http://www.asmail.be/msg0055568584.html
--              19) http://libpsd.graphest.com/files/Photoshop%20File%20Formats.pdf
--              20) http://tiki-lounge.com/~raf/tiff/fields.html
--              21) http://community.roxen.com/developers/idocs/rfc/rfc3949.html
--              22) http://tools.ietf.org/html/draft-ietf-fax-tiff-fx-extension1-01
--              23) MetaMorph Stack (STK) Image File Format:
--                  --> ftp://ftp.meta.moleculardevices.com/support/stack/STK.doc
--              24) http://www.cipa.jp/std/documents/e/DC-008-2012_E.pdf (Exif 2.3)
--              25) Vesa Kivisto private communication (7D)
--              26) Jeremy Brown private communication
--              27) Gregg Lee private communication
--              28) http://wwwimages.adobe.com/www.adobe.com/content/dam/Adobe/en/devnet/cinemadng/pdfs/CinemaDNG_Format_Specification_v1_1.pdf
--              29) http://www.libtiff.org
--              30) http://geotiff.maptools.org/spec/geotiffhome.html
--              31) https://android.googlesource.com/platform/external/dng_sdk/+/refs/heads/master/source/dng_tag_codes.h
--              32) Jeffry Friedl private communication
--              33) https://www.cipa.jp/std/documents/download_e.html?DC-008-Translation-2023-E (Exif 3.0)
--              IB) Iliah Borg private communication (LibRaw)
--              JD) Jens Duttke private communication
--
-- Port notes:   read-path subset; conversions that need the ExifTool object
--               take it as their first argument (upstream &$conv($val, $self)
--               shape); PrintConv lookup maps are plain Lua tables.
--               ProcessExif carries upstream's Validate-gated checks
--               (Exif.pm:6500 ValidateExif, 6511-6527 offset checks,
--               7176-7199 %offsetInfo + ValidateOffsetInfo); see
--               Validate.lua's Port notes for the ones still missing.
--               `Main` carries all 597 upstream tag ID's, in upstream order.
--               Every SubDirectory target table of `Main` exists in the port
--               (ProcessExif would warn and skip a missing one).
--               `ReadFromRAF` (ImageSourceData) is honoured when the value is
--               read from the file: the RAF is left at the value start for
--               the subdirectory, and a value over BINARY_DATA_LIMIT is only
--               read if requested.
--               `$$dirInfo{FixOffsets}` is a Lua function instead of an
--               eval string; it returns the new valuePtr/valEnd (upstream
--               modifies them in place).  Maker notes are extracted as a
--               block (MakerNotes option, or the tag requested) through the
--               `%makerDirInfo` rebuild, as upstream; the Composite
--               embedded-image tags are writable (WriteAlso, 0xfeedfeed).
--               The Composite table keeps its own (non-upstream) order.
--               A Composite RawConv takes @val as its value argument and the
--               hash of tag keys (upstream's $val) as its 4th; the further
--               embedded images (PreviewImage's second preview, the
--               OtherImage/PreviewJXL loops) go through FoundTag with such
--               a hash, as upstream.
--               Deferred on the write side: CompositeImageExposureTimes'
--               RawConvInv (needs a pack-style SetRational64u, which this
--               port does not have).
--------------------------------------------------------------------------------

local MakerNotes = require('lexiftool.MakerNotes')
local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local substr = perl.substr
local matches, unpack_ = perl.matches, perl.unpack
local isMatch = perl.isMatch
local perlTruthy = perl.truthy
local length = perl.length
local subst = perl.subst
local tr, split, findAll = perl.tr, perl.split, perl.findAll
local sprintf = perl.sprintf
local tsort = perl.tsort
local perlStr = perl.str
local lc = perl.lc

local Exif = {}

-- byte sizes for the various EXIF format types below
Exif.formatSize = { 1,1,2,4,8,1,1,2,4,8,4,8,4,2,8,8,8,8 }
Exif.formatSize[129] = 1 -- (Exif 3.0)

Exif.formatName = {
    'int8u',      'string',     'int16u',
    'int32u',     'rational64u','int8s',      'undef',
    'int16s',     'int32s',     'rational64s','float',
    'double',     'ifd',        'unicode',    'complex',
    'int64u',     'int64s',     'ifd64', -- (new BigTIFF formats)
}
Exif.formatName[129] = 'utf8' -- (Exif 3.0)

-- hash to look up EXIF format numbers by name
-- (format types are all lower case)
Exif.formatNumber = {
    ['int8u']       = 1,  -- BYTE
    ['string']      = 2,  -- ASCII
    ['int16u']      = 3,  -- SHORT
    ['int32u']      = 4,  -- LONG
    ['rational64u'] = 5,  -- RATIONAL
    ['int8s']       = 6,  -- SBYTE
    ['undef']       = 7,  -- UNDEFINED
    ['binary']      = 7,  -- (same as undef)
    ['int16s']      = 8,  -- SSHORT
    ['int32s']      = 9,  -- SLONG
    ['rational64s'] = 10, -- SRATIONAL
    ['float']       = 11, -- FLOAT
    ['double']      = 12, -- DOUBLE
    ['ifd']         = 13, -- IFD (with int32u format)
    ['unicode']     = 14, -- UNICODE [see Note below]
    ['complex']     = 15, -- COMPLEX [see Note below]
    ['int64u']      = 16, -- LONG8 [BigTIFF]
    ['int64s']      = 17, -- SLONG8 [BigTIFF]
    ['ifd64']       = 18, -- IFD8 (with int64u format) [BigTIFF]
    ['utf8']        = 129,-- UTF-8 (Exif 3.0)
    -- Note: unicode and complex types are not yet properly supported by ExifTool.
    -- These are types which have been observed in the Adobe DNG SDK code, but
    -- aren't fully supported there either.  We know the sizes, but that's about it.
    -- We don't know if the unicode is null terminated, or the format for complex
    -- (although I suspect it would be two 4-byte floats, real and imaginary).
}

-- EXIF LightSource values (upstream %lightSource, used by the ExifIFD
-- LightSource tag)
local lightSource = {
    [0] = 'Unknown',
    [1] = 'Daylight',
    [2] = 'Fluorescent',
    [3] = 'Tungsten (Incandescent)',
    [4] = 'Flash',
    [9] = 'Fine Weather',
    [10] = 'Cloudy',
    [11] = 'Shade',
    [12] = 'Daylight Fluorescent',   -- (D 5700 - 7100K)
    [13] = 'Day White Fluorescent',  -- (N 4600 - 5500K)
    [14] = 'Cool White Fluorescent', -- (W 3800 - 4500K)
    [15] = 'White Fluorescent',      -- (WW 3250 - 3800K)
    [16] = 'Warm White Fluorescent', -- (L 2600 - 3250K)
    [17] = 'Standard Light A',
    [18] = 'Standard Light B',
    [19] = 'Standard Light C',
    [20] = 'D55',
    [21] = 'D65',
    [22] = 'D75',
    [23] = 'D50',
    [24] = 'ISO Studio Tungsten',
    [25] = 'Daylight', -- Exif3.1
    [26] = 'Day White', -- Exif3.1
    [27] = 'Cool White', -- Exif3.1
    [28] = 'White', -- Exif3.1
    [29] = 'Warm White', -- Exif3.1
    [30] = 'Daylight LED',  -- Exif3.1 (D 5700-7100K)
    [31] = 'Day White LED', -- Exif3.1 (N 4600-5500K)
    [32] = 'Cool White LED',-- Exif3.1 (W 3800-4500K)
    [33] = 'White LED',     -- Exif3.1 (WW 3250-3800K)
    [34] = 'Warm White LED',-- Exif3.1 (L 2600-3250K)
    [255] = 'Other',
}
Exif.lightSource = lightSource

-- flash lookup (upstream %flash, used by the ExifIFD Flash tag)
local flash = {
    OTHER = function(val, inv)
        -- translate "Off" and "On" when writing
        if not (inv and matches(val, [[(?i)^(off|on)$]])) then return nil end
        return lc(val) == 'off' and 0x00 or 0x01
    end,
    [0x00] = 'No Flash',
    [0x01] = 'Fired',
    [0x05] = 'Fired, Return not detected',
    [0x07] = 'Fired, Return detected',
    [0x08] = 'On, Did not fire', -- not charged up?
    [0x09] = 'On, Fired',
    [0x0d] = 'On, Return not detected',
    [0x0f] = 'On, Return detected',
    [0x10] = 'Off, Did not fire',
    [0x14] = 'Off, Did not fire, Return not detected',
    [0x18] = 'Auto, Did not fire',
    [0x19] = 'Auto, Fired',
    [0x1d] = 'Auto, Fired, Return not detected',
    [0x1f] = 'Auto, Fired, Return detected',
    [0x20] = 'No flash function',
    [0x30] = 'Off, No flash function',
    [0x41] = 'Fired, Red-eye reduction',
    [0x45] = 'Fired, Red-eye reduction, Return not detected',
    [0x47] = 'Fired, Red-eye reduction, Return detected',
    [0x49] = 'On, Red-eye reduction',
    [0x4d] = 'On, Red-eye reduction, Return not detected',
    [0x4f] = 'On, Red-eye reduction, Return detected',
    [0x50] = 'Off, Red-eye reduction',
    [0x58] = 'Auto, Did not fire, Red-eye reduction',
    [0x59] = 'Auto, Fired, Red-eye reduction',
    [0x5d] = 'Auto, Fired, Red-eye reduction, Return not detected',
    [0x5f] = 'Auto, Fired, Red-eye reduction, Return detected',
}
Exif.flash = flash

-- Format an exposure time (upstream Exif.pm PrintExposureTime)
local function PrintExposureTime(secs)
    if type(secs) ~= 'number' then
        local n = tonumber(secs)
        if n == nil then return secs end
        secs = n
    end
    if secs < 0.25001 and secs > 0 then
        return sprintf('1/%d', math.floor(0.5 + 1 / secs))
    end
    local s = sprintf('%.1f', secs)
    s = s:gsub('%.0$', '')
    return s
end

-- Format an F number (upstream Exif.pm PrintFNumber)
local function PrintFNumber(val)
    val = tonumber(val) or val
    if type(val) == 'number' and val > 0 then
        -- round to 1 decimal place, or 2 for values < 1.0
        val = sprintf(val < 1 and '%.2f' or '%.1f', val)
    end
    return val
end

-- Convert fraction or number to floating point value (upstream Exif.pm
-- ConvertFraction; used as ShutterSpeedValue's PrintConvInv below)
local function ConvertFraction(val)
    local s = perlStr(val)
    local n, d = s:match('([%-%+]?%d+)/(%d+)')
    if n then
        d = tonumber(d)
        if d ~= 0 then return perlStr(tonumber(n) / d) end
        return tonumber(n) ~= 0 and 'inf' or 'undef'
    end
    return val
end

-- exported for other modules that reference these upstream PrintConv
-- helpers directly (e.g. Lytro.pm's DevicesLens*/DevicesShutter* tags)
Exif.PrintExposureTime = PrintExposureTime
Exif.PrintFNumber = PrintFNumber
Exif.ConvertFraction = ConvertFraction

-- Convert the coded text in UserComment, GPSProcessingMethod and
-- GPSAreaInformation (upstream Exif.pm ConvertExifText, ASCII/UNICODE/JIS
-- subset; the Validate-only warnings and WrongByteOrder detection are not
-- ported since they're diagnostics-only, not needed to compute the value)
-- Inputs: 0) ExifTool object, 1) val, 2) asciiFlex, 3) optional tag name
local function ConvertExifText(et, val, asciiFlex, tag)
    if length(val) < 8 then return val end
    local id = substr(val, 0, 8)
    local str = substr(val, 8)
    local isAsciiPrefix, isNulOrSpace = matches(id, [[^(ASCII)?(\0|[\0 ]+$)]])
    if isAsciiPrefix or isNulOrSpace then
        -- truncate at null terminator
        local nul = str:find('\0', 1, true)
        if nul then str = str:sub(1, nul - 1) end
        if asciiFlex == '1' then
            local enc = et:Options('CharsetEXIF')
            if ExifTool.perlTruthy(enc) then str = et:Decode(str, enc) end
        end
    elseif id:match('^UNICODE[%z ]$') then
        str = et:Decode(str, 'UTF16', 'Unknown')
    elseif id:match('^JIS[%z ][%z ][%z ][%z ][%z ]$') then
        str = et:Decode(str, 'JIS', 'Unknown')
    else
        if asciiFlex and asciiFlex ~= '1' then tag = asciiFlex end
        et:Warn('Invalid EXIF text encoding' .. (tag and (' for ' .. perlStr(tag)) or ''))
        str = id .. str
    end
    str = str:gsub(' +$', '') -- trim trailing blanks
    return str
end
Exif.ConvertExifText = ConvertExifText

--------------------------------------------------------------------------------
-- Identify RAW file type for some TIFF-based formats using Compression value
-- Inputs: 0) ExifTool object reference, 1) Compression value
-- - sets TIFF_TYPE and FileType if identified
--------------------------------------------------------------------------------
function Exif.IdentifyRawFile(et, comp)
    if et.FILE_TYPE == 'TIFF' and not perlTruthy(et.IdentifiedRawFile) then
        local c = Exif.compression[perl.num(comp)]
        local typ = c and matches(c, [[^\w+ ([A-Z]{3}) Compressed$]])
        if typ then
            et.TIFF_TYPE = typ
            et:OverrideFileType(et.TIFF_TYPE)
            et.IdentifiedRawFile = 1
        end
    end
end

-- Calculate LV (Light Value)
-- Inputs: 0) Aperture, 1) ShutterSpeed, 2) ISO
-- Returns: LV value (and converts input values to floating point if necessary)
local function CalculateLV(...)
    local args = { ... }
    -- do validity checks on arguments
    if select('#', ...) < 3 then return nil end
    for i = 1, 3 do
        local c1 = perlTruthy(args[i]) and matches(perlStr(args[i]), [[([+-]?(?=\d|\.\d)\d*(\.\d*)?([Ee]([+-]?\d+))?)]])
        if not (c1 and perl.num(c1) > 0) then return nil end
        -- extract float from any other garbage (as a float: Perl's product
        -- below turns into an NV where a Lua integer would wrap)
        args[i] = perl.num(c1) + 0.0
    end
    -- (A light value of 0 is defined as f/1.0 at 1 second with ISO 100)
    return math.log(args[1] * args[1] * 100 / (args[2] * args[3])) / math.log(2)
end

-- Calculate scale factor for 35mm effective focal length (upstream Exif.pm
-- CalcScaleFactor35efl, read subset: the ExifTool object's DoAltComposite/
-- alternate-file handling is write/multi-file only and not ported).
-- Inputs: 0) ExifTool object ref, 1) val (the composite's 0-based Desire
--         table: see Exif.Composite.ScaleFactor35efl below for the index
--         mapping)
-- Returns: 35mm conversion factor, or nil
local function CalcScaleFactor35efl(et, val)
    local focal = tonumber(val[0])
    local foc35 = tonumber(val[1])
    if focal and focal ~= 0 and foc35 and foc35 ~= 0 then
        return foc35 / focal
    end
    local digz = tonumber(val[2])
    if not perlTruthy(digz) then digz = 1 end
    local diag = tonumber(val[3])
    local sens = tonumber(val[4])
    local sensXY = val[4]
    -- calculate Canon sensor size using a dedicated algorithm
    -- (require here, not at module load, so a non-Canon file never pulls in
    -- lexiftool.Canon -- matching upstream, where Canon.pm is only ever
    -- require'd when actually needed. This also keeps BuildCompositeTags'
    -- package.loaded check accurate: a non-Canon file must never make
    -- package.loaded['lexiftool.Canon'] true, or Canon's Composite table
    -- would spuriously gate same-named bare Desire/Require tags, e.g.
    -- RedBalance's 'WB_RGGBLevels', on files that never touch Canon data.)
    if et.Make == 'Canon' then
        local canonDiag = require('lexiftool.Canon').CalcSensorDiag(et)
        if canonDiag then diag = canonDiag end
    end
    if not (perlTruthy(diag) and et.IsFloat(diag)) then
        diag = nil
        if sens and type(sensXY) == 'string' then
            local n = sensXY:match('[ \t\n\r\f\v](%d+%.?%d*)$')
            if n then diag = math.sqrt(sens * sens + tonumber(n) * tonumber(n)) end
        end
        if not diag then
            -- validate by checking aspect ratio because FocalPlaneX/YSize is not reliable
            local xsize = tonumber(val[5])
            local ysize = tonumber(val[6])
            if xsize and xsize ~= 0 and ysize and ysize ~= 0 then
                local a = xsize / ysize
                if math.abs(a - 1.3333) < 0.1 or math.abs(a - 1.5) < 0.1 then
                    diag = math.sqrt(xsize * xsize + ysize * ysize)
                end
            end
        end
        if not diag then
            -- get number of mm in units (assume inches unless otherwise specified)
            local lkup = { [3] = 10, [4] = 1, [5] = 0.001, cm = 10, mm = 1, um = 0.001 }
            -- val[7] may come through as either a Lua number or a numeric
            -- string (GetValue does not normalize types), so try both --
            -- Lua table lookups are type-sensitive unlike Perl's autoviv
            -- string/number equivalence
            local units = (val[7] and (lkup[val[7]] or lkup[tonumber(val[7])])) or 25.4
            local xres = tonumber(val[8])
            if not (xres and xres ~= 0) then return nil end
            local yres = tonumber(val[9]) or xres
            if yres == 0 then return nil end
            -- find the first image width/height pair with a reasonable aspect ratio
            local w, h
            for _, p in ipairs({ { 10, 11 }, { 12, 13 }, { 14, 15 } }) do
                local ww, hh = tonumber(val[p[1]]), tonumber(val[p[2]])
                if ww and hh and ww ~= 0 and hh ~= 0 then
                    local a = ww / hh
                    if a > 0.5 and a < 2 then
                        w, h = ww, hh
                        break
                    end
                end
            end
            if not (w and h) then return nil end
            -- calculate focal plane size in mm
            -- (upstream's `$w *= $units / $x_res` multiplies by the quotient;
            --  `w * units / xres` would divide the product instead and differ
            --  in the last bit -- visible in -n output, e.g. Canon.jpg's
            --  FocalLength35mmEquiv)
            w = w * (units / xres)
            h = h * (units / yres)
            diag = math.sqrt(w * w + h * h)
            -- make sure size is reasonable
            if not (diag > 1 and diag < 100) then return nil end
        end
    end
    return math.sqrt(36 * 36 + 24 * 24) * digz / diag
end

-- Perl `int()` truncates toward zero (unlike Lua's math.floor, which rounds
-- toward negative infinity -- they differ for negative non-integers)
local function perlInt(v)
    return v >= 0 and math.floor(v) or math.ceil(v)
end

-- Print a fraction (upstream Exif.pm PrintFraction)
local function PrintFraction(val)
    local str
    if val ~= nil then
        val = perl.num(val, '*') * 1.00001    -- avoid round-off errors
        if not perlTruthy(val) then
            str = '0'
        elseif perlInt(val) / val > 0.999 then
            str = sprintf('%+d', perlInt(val))
        elseif (perlInt(val * 2)) / (val * 2) > 0.999 then
            str = sprintf('%+d/2', perlInt(val * 2))
        elseif (perlInt(val * 3)) / (val * 3) > 0.999 then
            str = sprintf('%+d/3', perlInt(val * 3))
        else
            str = sprintf('%+.3g', val)
        end
    end
    return str
end
Exif.PrintFraction = PrintFraction

--------------------------------------------------------------------------------
-- TimeCodes (upstream Exif.pm tag 0xc763, #28): SMPTE/DPX-style BCD
-- timecodes, up to 10 of them, 8 bytes each. Raw value is a space-separated
-- decimal-byte string (the generic int8u-array raw-value format this port
-- already uses elsewhere, e.g. ComponentsConfiguration above). ValueConv
-- groups those bytes into dot-separated 2-digit-hex groups (one group per
-- timecode); PrintConv decodes each group's BCD fields (frames/seconds/
-- minutes/hours, plus an optional embedded date+timezone when the BGF2
-- flag bit on the hours byte is set) into
-- "HH:MM:SS.FF[ YYYY-MM-DDTHH:MM:SS.FF+HH:MM]"; PrintConvInv/ValueConvInv
-- invert both steps for writing. A byte's "is this valid BCD" check works
-- by formatting it as 2-digit hex and checking for an a-f digit -- a valid
-- BCD byte's hex representation *is* its intended decimal digit pair by
-- construction (e.g. BCD byte 0x19 means the digits "1","9", and
-- string.format('%02x', 0x19) is literally "19").
--------------------------------------------------------------------------------
local function timeCodesValueConv(_self, val)
    local nums = {}
    for n in perlStr(val):gmatch('[^ \t\n\r\f\v]+') do nums[#nums + 1] = tonumber(n) end
    local groups = {}
    local i = 1
    while i + 7 <= #nums do
        local hexes = {}
        for j = i, i + 7 do hexes[#hexes + 1] = sprintf('%.2x', nums[j]) end
        groups[#groups + 1] = table.concat(hexes, '.')
        i = i + 8
    end
    return table.concat(groups, ' ')
end

local function timeCodesValueConvInv(_self, val)
    local out = {}
    for h in perlStr(val):gmatch('[^%. \t\n\r\f\v]+') do
        out[#out + 1] = perlStr(tonumber(h, 16))
    end
    return table.concat(out, ' ')
end

local function timeCodesPrintConv(self, val)
    local a = {}
    for h in perlStr(val):gmatch('[^%. \t\n\r\f\v]+') do a[#a + 1] = tonumber(h, 16) end
    local v = {}
    local i = 1
    while i + 7 <= #a do
        local b0, b1, b2, b3 = a[i], a[i + 1], a[i + 2], a[i + 3]
        local b4, b5, b6, b7 = a[i + 4], a[i + 5], a[i + 6], a[i + 7]
        local str = sprintf('%.2x:%.2x:%.2x.%.2x', b3 & 0x3f, b2 & 0x7f, b1 & 0x7f, b0 & 0x3f)
        if b3 & 0x80 ~= 0 then -- BGF2 set: date+timezone follow
            local tzByte = b7 & 0x3f
            local bzStr = sprintf('%.2x', tzByte)
            local bz = bzStr:match('[a-f]') and 100 or tonumber(bzStr)
            local tz
            if bz < 26 then
                tz = (bz < 13 and 0 or 26) - bz
            elseif bz == 32 then
                tz = 12.75
            elseif bz >= 28 and bz <= 31 then
                tz = 0
            elseif bz < 100 then
                tz = nil
            elseif tzByte < 0x20 then
                tz = ((tzByte < 0x10 and 10 or 20) - tzByte) - 0.5
            else
                tz = ((tzByte < 0x30 and 53 or 63) - tzByte) + 0.5
            end
            if b7 & 0x80 ~= 0 then -- MJD format (with UTC time)
                local h1, m1, s1, f1 = str:match('^(%x%x):(%x%x):(%x%x)%.(%x%x)$')
                local jday = tonumber(sprintf('%x%.2x%.2x', b6, b5, b4))
                local unixTime = (jday - 40587) * 86400 + (((tonumber(h1) + (tz or 0)) * 60) + tonumber(m1)) * 60 + tonumber(s1)
                str = self.ConvertUnixTime(unixTime) .. '.' .. f1
                str = (str:gsub('^(%d+):(%d+):(%d+) ', '%1-%2-%3T'))
            else -- YYMMDD
                local yr = tonumber(sprintf('%.2x', b6)) + 1900
                if yr < 1970 then yr = yr + 100 end
                str = sprintf('%d-%.2x-%.2xT%s', yr, b5, b4, str)
            end
            if tz ~= nil then str = str .. ExifTool.TimeZoneString(tz * 60) end
        end
        v[#v + 1] = str
        i = i + 8
    end
    return table.concat(v, ' ')
end

local function timeCodesPrintConvInv(_self, val)
    local out = {}
    for tok in perlStr(val):gmatch('[^ \t\n\r\f\v]+') do
        local datePart, timePart = tok:match('^(.-)T(.+)$')
        if not timePart then timePart = tok end
        local tz = 0x39 -- default: unknown timezone
        local sign, tzh, tzm = timePart:match('([%-%+])(%d+):(%d+)$')
        if sign then
            timePart = timePart:sub(1, #timePart - (1 + #tzh + 1 + #tzm))
            local h2, m2 = tonumber(tzh), tonumber(tzm)
            if m2 == 0 then
                tz = (sign == '-') and h2 or (0x26 - h2)
            elseif m2 == 30 then
                if sign == '-' then
                    tz = h2 + 0x0a
                    if tz > 0x0f then tz = tz + 0x0a end
                else
                    tz = 0x3f - h2
                    if tz < 0x3a then tz = tz - 0x0a end
                end
            elseif m2 == 45 and sign == '+' and h2 == 12 then
                tz = 0x32
            end
        end
        local t = {}
        for field in timePart:gmatch('[^:.]+') do t[#t + 1] = field end
        while #t < 4 do t[#t + 1] = '00' end
        local bg = '.00.00.00.00'
        local ok = true
        if datePart and #datePart > 0 then
            local d = {}
            for f in datePart:gmatch('[^%-]+') do d[#d + 1] = f end
            if #d >= 3 then
                local day, month, yr2 = tonumber(d[3]), tonumber(d[2]), tonumber(d[1]) % 100
                bg = sprintf('.%.2d.%.2d.%.2d.%.2x', day, month, yr2, tz)
                t[1] = sprintf('%.2x', tonumber(t[1], 16) + 0xc0) -- set BGF1+BGF2
            else
                ok = false -- malformed date: drop this timecode (matches upstream's `next`)
            end
        end
        if ok then
            out[#out + 1] = string.format('%s.%s.%s.%s%s', t[4], t[3], t[2], t[1], bg)
        end
    end
    return table.concat(out, ' ')
end

-- Print lens info in the form "12-34mm f/3.5-5.6" (upstream Exif.pm
-- PrintLensInfo; its inverse is WriteExif.ConvertLensInfo)
local function PrintLensInfo(val)
    local vals = {}
    for w in perlStr(val):gmatch('[^ \t\n\r\f\v]+') do vals[#vals + 1] = w end
    if #vals ~= 4 then return val end
    local c = 0
    for i = 1, 4 do
        if ExifTool.IsFloat(vals[i]) then
            c = c + 1
        elseif vals[i] == 'inf' or vals[i] == 'undef' then
            vals[i] = '?'
            c = c + 1
        end
    end
    if c ~= 4 then return val end
    local out = vals[1]
    if vals[2] ~= '0' and vals[2] ~= vals[1] then out = out .. '-' .. vals[2] end
    out = out .. 'mm f/' .. vals[3]
    if vals[4] ~= '0' and vals[4] ~= vals[3] then out = out .. '-' .. vals[4] end
    return out
end
Exif.PrintLensInfo = PrintLensInfo

-- Convert parameter back to standard EXIF value
--   0,0.00,etc or "Normal" => 0
--   -1,-2,etc or "Soft" or "Low" => 1
--   +1,+2,1,2,etc or "Hard" or "High" => 2
-- (Exif.pm:5647, used as PrintConvInv for Contrast/Saturation/Sharpness)
local function ConvertParameter(_self, val)
    val = perlStr(val)
    local isFloat = ExifTool.IsFloat(val)
    local num = tonumber(val)
    -- normal is a value of zero
    if matches(val, [[(?i)\bn]]) or (isFloat and num == 0) then return 0 end
    -- "soft", "low" or any negative number is a value of 1
    if matches(val, [[(?i)\b(s|l)]]) or (isFloat and num < 0) then return 1 end
    -- "hard", "high" or any positive number is a value of 2
    if matches(val, [[(?i)\bh]]) or isFloat then return 2 end
    return nil
end
Exif.ConvertParameter = ConvertParameter

-- CFA color names (upstream @cfaColor, used by PrintCFAPattern)
local cfaColor = { [0] = 'Red', [1] = 'Green', [2] = 'Blue', [3] = 'Cyan', [4] = 'Magenta', [5] = 'Yellow', [6] = 'White' }

-- Decode CFAPattern into a space-separated "width height v0 v1 ..." string
-- (upstream DecodeCFAPattern)
local function DecodeCFAPattern(self, val)
    -- some panasonic cameras (SV-AS3, SV-AS30) write this in ascii (very odd)
    if matches(val, [[^[0-6]+$]]) then
        self:Warn('Incorrectly formatted CFAPattern', 1)
        val = val:gsub('[0-6]', function(c) return string.char(tonumber(c)) end)
    end
    if #val < 4 then return val end
    local a = { unpack_(ExifTool.GetByteOrder() == 'II' and 'v2C*' or 'n2C*', val) }
    local endPos = 2 + a[1] * a[2]
    if endPos > #a then
        -- try swapping byte order (I have seen this order different than in EXIF)
        -- (swap the high/low bytes of each 16-bit dimension value directly,
        -- equivalent to upstream's pack('v2',...)/unpack('n2',...) round trip)
        local x = ((a[1] & 0xff) << 8) | ((a[1] >> 8) & 0xff)
        local y = ((a[2] & 0xff) << 8) | ((a[2] >> 8) & 0xff)
        if #a < 2 + x * y then
            self:Warn('Invalid CFAPattern', 1)
        else
            a[1], a[2] = x, y
        end
    end
    return table.concat(a, ' ')
end
Exif.DecodeCFAPattern = DecodeCFAPattern

-- Print CFA Pattern (upstream PrintCFAPattern)
local function PrintCFAPattern(val)
    local w = {}
    for tok in perlStr(val):gmatch('[^ \t\n\r\f\v]+') do w[#w + 1] = tonumber(tok) end
    if #w < 2 then return '<truncated data>' end
    local a0, a1 = w[1], w[2]
    if a0 == 0 or a1 == 0 then return '<zero pattern size>' end
    local endP = 2 + a0 * a1 -- (Perl 0-indexed exclusive end)
    if endP > #w then return '<invalid pattern size>' end
    local pos, rtnVal = 2, '[' -- (Perl 0-indexed pos; w[pos+1] converts to Lua 1-indexing)
    while true do
        rtnVal = rtnVal .. (cfaColor[w[pos + 1]] or 'Unknown')
        pos = pos + 1
        if pos >= endP then break end
        if (pos - 2) % a1 ~= 0 then
            rtnVal = rtnVal .. ','
        else
            rtnVal = rtnVal .. '][' -- close the previous row, open the next
        end
    end
    return rtnVal .. ']'
end
Exif.PrintCFAPattern = PrintCFAPattern

-- lookup for integer format strings
Exif.intFormat = {
    ['int8u']  = 1,
    ['int16u'] = 3,
    ['int32u'] = 4,
    ['int8s']  = 6,
    ['int16s'] = 8,
    ['int32s'] = 9,
    ['ifd']    = 13,
    ['int64u'] = 16,
    ['int64s'] = 17,
    ['ifd64']  = 18,
}

-- size limit for loading binary data block into memory
function Exif.BINARY_DATA_LIMIT() return 10 * 1024 * 1024 end

-- TIFF Compression values
-- (values with format "Xxxxx XXX Compressed" are used to identify RAW file types)
Exif.compression = {
    [1] = 'Uncompressed',
    [2] = 'CCITT 1D',
    [3] = 'T4/Group 3 Fax',
    [4] = 'T6/Group 4 Fax',
    [5] = 'LZW',
    [6] = 'JPEG (old-style)', -- #3
    [7] = 'JPEG', -- #4
    [8] = 'Adobe Deflate', -- #3
    [9] = 'JBIG B&W or VC-5', -- #3 / github411
    [10] = 'JBIG Color', -- #3
    [99] = 'JPEG', -- #16
    [262] = 'Kodak 262', -- #16
    [32766] = 'NeXt or Sony ARW Compressed 2', -- #3/Milos
    [32767] = 'Sony ARW Compressed', -- #16
    [32769] = 'Packed RAW', -- #PH (used by Epson, Nikon, Samsung)
    [32770] = 'Samsung SRW Compressed', -- #PH
    [32771] = 'CCIRLEW', -- #3
    [32772] = 'Samsung SRW Compressed 2', -- #PH (NX3000,NXmini)
    [32773] = 'PackBits',
    [32809] = 'Thunderscan', -- #3
    [32867] = 'Kodak KDC Compressed', -- #PH
    [32895] = 'IT8CTPAD', -- #3
    [32896] = 'IT8LW', -- #3
    [32897] = 'IT8MP', -- #3
    [32898] = 'IT8BL', -- #3
    [32908] = 'PixarFilm', -- #3
    [32909] = 'PixarLog', -- #3
  -- 32910,32911 - Pixar reserved
    [32946] = 'Deflate', -- #3
    [32947] = 'DCS', -- #3
    [33003] = 'Aperio JPEG 2000 YCbCr', -- #https://openslide.org/formats/aperio/
    [33005] = 'Aperio JPEG 2000 RGB', -- #https://openslide.org/formats/aperio/
    [34661] = 'JBIG', -- #3
    [34676] = 'SGILog', -- #3
    [34677] = 'SGILog24', -- #3
    [34712] = 'JPEG 2000', -- #3
    [34713] = 'Nikon NEF Compressed', -- #PH
    [34715] = 'JBIG2 TIFF FX', -- #20
    [34718] = 'Microsoft Document Imaging (MDI) Binary Level Codec', -- #18
    [34719] = 'Microsoft Document Imaging (MDI) Progressive Transform Codec', -- #18
    [34720] = 'Microsoft Document Imaging (MDI) Vector', -- #18
    [34887] = 'ESRI Lerc', -- #LibTiff
  -- 34888,34889 - ESRI reserved
    [34892] = 'Lossy JPEG', -- # (DNG 1.4)
    [34925] = 'LZMA2', -- #LibTiff
    [34926] = 'Zstd (old)', -- #LibTiff
    [34927] = 'WebP (old)', -- #LibTiff
    [34933] = 'PNG', -- # (TIFF mail list)
    [34934] = 'JPEG XR', -- # (TIFF mail list)
    [50000] = 'Zstd', -- #LibTiff 4.7
    [50001] = 'WebP', -- #LibTiff 4.7
    [50002] = 'JPEG XL (old)', -- #LibTiff 4.7
    [52546] = 'JPEG XL', -- # (DNG 1.7)
    [65000] = 'Kodak DCR Compressed', -- #PH
    [65535] = 'Pentax PEF Compressed', -- #Jens
}

Exif.photometricInterpretation = {
    [0] = 'WhiteIsZero',
    [1] = 'BlackIsZero',
    [2] = 'RGB',
    [3] = 'RGB Palette',
    [4] = 'Transparency Mask',
    [5] = 'CMYK',
    [6] = 'YCbCr',
    [8] = 'CIELab',
    [9] = 'ICCLab', -- #3
    [10] = 'ITULab', -- #3
    [32803] = 'Color Filter Array', -- #2
    [32844] = 'Pixar LogL', -- #3
    [32845] = 'Pixar LogLuv', -- #3
    [32892] = 'Sequential Color Filter', -- #JR (Sony ARQ)
    [34892] = 'Linear Raw', -- #2
    [51177] = 'Depth Map', -- # (DNG 1.5)
    [52527] = 'Semantic Mask', -- # (DNG 1.6)
}

Exif.orientation = {
    [1] = 'Horizontal (normal)',
    [2] = 'Mirror horizontal',
    [3] = 'Rotate 180',
    [4] = 'Mirror vertical',
    [5] = 'Mirror horizontal and rotate 270 CW',
    [6] = 'Rotate 90 CW',
    [7] = 'Mirror horizontal and rotate 90 CW',
    [8] = 'Rotate 270 CW',
}

-- save the values of these tags for additional validation checks
Exif.saveForValidate = {
    [0x100] = 1, -- ImageWidth
    [0x101] = 1, -- ImageHeight
    [0x102] = 1, -- BitsPerSample
    [0x103] = 1, -- Compression
    [0x115] = 1, -- SamplesPerPixel
}

Exif.subfileType = {
    [0] = 'Full-resolution image',
    [1] = 'Reduced-resolution image',
    [2] = 'Single page of multi-page image',
    [3] = 'Single page of multi-page reduced-resolution image',
    [4] = 'Transparency mask',
    [5] = 'Transparency mask of reduced-resolution image',
    [6] = 'Transparency mask of multi-page image',
    [7] = 'Transparency mask of reduced-resolution multi-page image',
    [8] = 'Depth map', -- # (DNG 1.5)
    [9] = 'Depth map of reduced-resolution image', -- # (DNG 1.5)
    [16] = 'Enhanced image data', -- # (DNG 1.5)
    [0x10001] = 'Alternate reduced-resolution image', -- # (DNG 1.2)
    [0x10004] = 'Semantic Mask', -- # (DNG 1.6)
    [0xffffffff] = 'invalid', -- #(found in E5700 NEF's)
    BITMASK = {
        [0] = 'Reduced resolution',
        [1] = 'Single page',
        [2] = 'Transparency mask',
        [3] = 'TIFF/IT final page', -- #20 (repurposed as DepthMap repurposes by DNG 1.5)
        [4] = 'TIFF-FX mixed raster content', -- #20 (repurposed as EnhancedImageData by DNG 1.5)
    },
}

--------------------------------------------------------------------------------
-- Print SpatialFrequencyResponse (upstream PrintSFR)
-- Inputs: 0) value
-- Returns: converted value
local function PrintSFR(val)
    val = perlStr(val)
    if #val <= 4 then return val end
    local n, m = ExifTool.Get16u(val, 0), ExifTool.Get16u(val, 2)
    local cols = perl.split('\0', substr(val, 4), n + 1)
    local pos = #val - 8 * n * m
    if #cols ~= n + 1 or pos < 4 then return val end
    cols[#cols] = nil
    for i = 0, n - 1 do
        local rows = {}
        for j = 0, m - 1 do
            rows[#rows + 1] = ExifTool.GetRational64u(val, pos + 8 * (i + j * n))
        end
        cols[i + 1] = cols[i + 1] .. '=' .. perl.join(',', rows)
    end
    return perl.join('; ', cols)
end

--------------------------------------------------------------------------------
-- PrintConv for parameter tags (upstream PrintParameter -- the OTHER of the
-- %printParameter hash below; note the case: upstream has both a sub
-- PrintParameter and a hash printParameter, and so does this port)
-- Inputs: 0) value, 1) inverse flag
-- Returns: converted value
local function PrintParameter(val, inv)
    if inv then return val end
    val = tonumber(val) or val
    if type(val) == 'number' and val > 0 then
        if val > 0xfff0 then    -- a negative value in disguise?
            val = val - 0x10000
        else
            val = '+' .. val
        end
    end
    return val
end

-- PrintConv for parameter tags
-- (upstream is %Image::ExifTool::Exif::printParameter, spread into a tag entry;
--  conventions.md §2 turns a spread hash into a helper)
local function printParameter(t)
    t.PrintConv = {
        [0] = 'Normal',
        OTHER = function(val, inv) return PrintParameter(val, inv) end,
    }
    return t
end

Exif.printParameter = printParameter

-- convert DNG UTF-8 string values (may be string or int8u format)
local function utf8StringConv(t)
    t.Writable = 'string'
    t.Format = 'string'
    t.ValueConv = function(self, val) return self:Decode(val, 'UTF8') end
    t.ValueConvInv = function(self, val) return self:Encode(val, 'UTF8') end
    return t
end

-- ValueConv that makes long values binary type
local function longBin(t)
    t.ValueConv = function(_self, val)
        if type(val) == 'string' and #val > 64 then
            return { ref = 'SCALAR', value = val }
        end
        return val
    end
    t.ValueConvInv = function(_self, val) return val end
    t.LongBinary = 1        -- flag to avoid decoding values of a large array
    return t
end

-- PrintConv for SampleFormat (0x153)
local sampleFormat = {
    [1] = 'Unsigned',        -- unsigned integer
    [2] = 'Signed',          -- two's complement signed integer
    [3] = 'Float',           -- IEEE floating point
    [4] = 'Undefined',
    [5] = 'Complex int',     -- complex integer (ref 3)
    [6] = 'Complex float',   -- complex IEEE floating point (ref 3)
}

-- Print DNG opcode list (upstream PrintOpcode)
-- Inputs: 0) value ref, 1) inverse flag, 2) PrintConv hash ref
-- Returns: opcode list string
local function PrintOpcode(val, inv, conv)
    if inv then return nil end   -- (can't do inverse conversion)
    val = type(val) == 'table' and val.value or val
    if #perlStr(val) <= 4 then return '' end
    local num = perl.unpack('N', val)
    local pos = 4
    local ops = {}
    for _ = 1, num do
        if pos + 16 > #val then ops[#ops + 1] = '<err>'; break end
        local op = ExifTool.Get32u(val, pos)
        local len = ExifTool.Get32u(val, pos + 12)
        ops[#ops + 1] = conv[op] or ('[opcode ' .. op .. ']')
        pos = pos + 16 + len
    end
    return perl.join(', ', ops)
end

-- conversions for DNG OpcodeList tags
local function opcodeInfo(t)
    t.Writable = 'undef'
    t.WriteGroup = 'SubIFD'
    t.Protected = 1
    t.Binary = 1
    t.ConvertBinary = 1 -- needed because the ValueConv value is binary
    t.PrintConvColumns = 2
    t.PrintConv = {
        OTHER = function(val, inv, conv) return PrintOpcode(val, inv, conv) end,
        [1] = 'WarpRectilinear',
        [2] = 'WarpFisheye',
        [3] = 'FixVignetteRadial',
        [4] = 'FixBadPixelsConstant',
        [5] = 'FixBadPixelsList',
        [6] = 'TrimBounds',
        [7] = 'MapTable',
        [8] = 'MapPolynomial',
        [9] = 'GainMap',
        [10] = 'DeltaPerRow',
        [11] = 'DeltaPerColumn',
        [12] = 'ScalePerRow',
        [13] = 'ScalePerColumn',
        [14] = 'WarpRectilinear2', -- (DNG 1.6)
    }
    t.PrintConvInv = false  -- (so the inverse conversion is not performed)
    return t
end

-- lookups for LearningOptOutIn tag
local use = {
    [0] = 'All / Individual Usage Not Specified',
    [1] = 'Non-Generative AI/ML Training',
    [2] = 'Generative AI/ML Training',
    [3] = 'Data Mining',
    [4] = 'Input to Foundation Model (Trained AI/ML Model)',
}
local ind = {
    [0] = 'Opt-out',
    [1] = 'Opt-in',
    [2] = 'Unspecified',
}

-- (port helpers for the 0x111/0x117 conditional lists below: upstream's
--  `$$self{Compression} and $$self{Compression} eq "34892"`, and the A200
--  ValueConv `$val=join(" ",unpack("N*",pack("V*",split(" ",$val))));\$val`)
local function compressionIs(self, code)
    local c = self.Compression
    return ExifTool.perlTruthy(c) and (type(c) == 'number' and ExifTool.NumStr(c) or perlStr(c)) == code
end
local function a200ValueConv(_self, val)
    -- (Perl's `split(" ", ...)` is awk mode: leading whitespace dropped, then
    --  split on /\s+/)
    local vals = perl.split([[\s+]], (perlStr(val):gsub('^[ \t\n\r\f\v]+', '')))
    val = perl.join(' ', { perl.unpack('N*', perl.pack('V*', table.unpack(vals))) })
    return { ref = 'SCALAR', value = val }
end

-- main EXIF tag table
Exif.Main = {
    GROUPS = { [0] = 'EXIF', [1] = 'IFD0', [2] = 'Image' },
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    WRITE_GROUP = 'ExifIFD', -- default write group (upstream Exif.pm)
    SET_GROUP1 = true, -- set group1 name to directory name for all tags in table
    [0x1] = {
        Name = 'InteropIndex',
        Description = 'Interoperability Index',
        Protected = 1,
        Writable = 'string',
        WriteGroup = 'InteropIFD',
        PrintConv = {
            R98 = 'R98 - DCF basic file (sRGB)',
            R03 = 'R03 - DCF option file (Adobe RGB)',
            THM = 'THM - DCF thumbnail file',
        },
    },
    [0x2] = { --5 (not in the EXIF spec)
        Name = 'InteropVersion',
        Description = 'Interoperability Version',
        Protected = 1,
        Writable = 'undef',
        Mandatory = 1,
        WriteGroup = 'InteropIFD',
        RawConv = function(_self, val) return (perlStr(val):gsub('\0+$', '')) end,  -- (some idiots add null terminators)
    },
    [0x0b] = { --PH
        Name = 'ProcessingSoftware',
        Writable = 'string',
        WriteGroup = 'IFD0',
        Notes = 'used by ACD Systems Digital Imaging',
    },
    [0xfe] = {
        Name = 'SubfileType',
        Notes = 'called NewSubfileType by the TIFF specification',
        Protected = 1,
        Writable = 'int32u',
        WriteGroup = 'IFD0',
        -- set priority directory if this is the full resolution image
        DataMember = 'SubfileType',
        RawConv = function(self, val)
            if val == (val & 0x02) then
                if val == 0 then self:SetPriorityDir() end
                self.PageCount = (self.PageCount or 0) + 1
                if val == 2 or self.PageCount > 1 then self.MultiPage = 1 end
            end
            self.SubfileType = val
            return val
        end,
        PrintConv = Exif.subfileType,
    },
    [0xff] = {
        Name = 'OldSubfileType',
        Notes = 'called SubfileType by the TIFF specification',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        -- set priority directory if this is the full resolution image
        RawConv = function(self, val)
            if val == 1 or val == 3 then
                if val == 1 then self:SetPriorityDir() end
                self.PageCount = (self.PageCount or 0) + 1
                if val == 3 or self.PageCount > 1 then self.MultiPage = 1 end
            end
            return val
        end,
        PrintConv = {
            [1] = 'Full-resolution image',
            [2] = 'Reduced-resolution image',
            [3] = 'Single page of multi-page image',
        },
    },
    [0x100] = {
        Name = 'ImageWidth',
        Groups = { [1] = 'IFD1' }, -- register IFD1 so it shows up in the group lists
        Protected = 1,
        Writable = 'int32u',
        WriteGroup = 'IFD0',
        Priority = 0,
    },
    [0x101] = {
        Name = 'ImageHeight',
        Notes = 'called ImageLength by the EXIF spec.',
        Protected = 1,
        Writable = 'int32u',
        WriteGroup = 'IFD0',
        Priority = 0,
    },
    [0x102] = {
        Name = 'BitsPerSample',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Count = -1, -- can be 1 or 3: -1 means 'variable'
        Priority = 0,
    },
    [0x103] = {
        Name = 'Compression',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Mandatory = 1,
        DataMember = 'Compression',
        SeparateTable = 'Compression',
        RawConv = function(self, val)
            Exif.IdentifyRawFile(self, val)
            self.Compression = val
            return val
        end,
        PrintConv = Exif.compression,
        Priority = 0,
    },
    [0x106] = {
        Name = 'PhotometricInterpretation',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        PrintConv = Exif.photometricInterpretation,
        Priority = 0,
    },
    [0x107] = {
        Name = 'Thresholding',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        PrintConv = {
            [1] = 'No dithering or halftoning',
            [2] = 'Ordered dither or halftone',
            [3] = 'Randomized dither',
        },
    },
    [0x108] = {
        Name = 'CellWidth',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
    },
    [0x109] = {
        Name = 'CellLength',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
    },
    [0x10a] = {
        Name = 'FillOrder',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        PrintConv = {
            [1] = 'Normal',
            [2] = 'Reversed',
        },
    },
    [0x10d] = {
        Name = 'DocumentName',
        Writable = 'string',
        WriteGroup = 'IFD0',
    },
    [0x10e] = {
        Name = 'ImageDescription',
        Writable = 'string',
        WriteGroup = 'IFD0',
        Priority = 0,
    },
    [0x10f] = {
        Name = 'Make',
        Groups = { [2] = 'Camera' },
        Writable = 'string',
        WriteGroup = 'IFD0',
        DataMember = 'Make',
        -- remove trailing blanks and save as an ExifTool member variable
        RawConv = function(self, val)
            val = val:gsub('[ \t\n\r\f\v]+$', '')
            self.Make = val
            return val
        end,
        -- NOTE: trailing "blanks" (spaces) are removed from all EXIF tags which
        -- may be "unknown" (filled with spaces) according to the EXIF spec.
        -- This allows conditional replacement with "exiftool -TAG-= -TAG=VALUE".
        -- - also removed are any other trailing whitespace characters
    },
    [0x110] = {
        Name = 'Model',
        Description = 'Camera Model Name',
        Groups = { [2] = 'Camera' },
        Writable = 'string',
        WriteGroup = 'IFD0',
        DataMember = 'Model',
        RawConv = function(self, val)
            val = val:gsub('[ \t\n\r\f\v]+$', '')
            self.Model = val
            return val
        end,
    },
    [0x111] = {
        {
            Condition = function(self)
                return self.TIFF_TYPE == 'MRW' and self.DIR_NAME == 'IFD0' and
                    matches(perlStr(self.Model or ''), [[^DiMAGE A200]]) ~= nil
            end,
            Name = 'StripOffsets',
            IsOffset = 1,
            IsImageData = 1,
            OffsetPair = 0x117,  -- point to associated byte counts
            -- A200 stores this information in the wrong byte order!!
            ValueConv = a200ValueConv,
            ByteOrder = 'LittleEndian',
        },
        {
            Condition = function(self) return compressionIs(self, '34892') end, -- DNG Lossy JPEG
            Name = 'OtherImageStart',
            IsOffset = 1,
            IsImageData = 1,
            OffsetPair = 0x117,  -- point to associated byte counts
            DataTag = 'OtherImage',
        },
        {
            Condition = function(self) return compressionIs(self, '52546') end, -- DNG 1.7 Jpeg XL
            Name = 'PreviewJXLStart',
            IsOffset = 1,
            IsImageData = 1,
            OffsetPair = 0x117,  -- point to associated byte counts
            DataTag = 'PreviewJXL',
        },
        {
            -- (APP1 IFD2 is for Leica JPEG preview)
            Condition = function(self)
                local tf = self.TIFF_TYPE
                local dir = self.DIR_NAME
                -- (upstream's `$$self{Compression}` is the value found in the
                --  *current* directory -- for a DNG SubIFD1/SubIFD2 its own
                --  Compression=7 entry precedes this 0x111, so the value is 7
                --  here, not the IFD0 primary-slot value -- find it by group)
                local comp = self:FindValue('Compression', dir)
                return not (tf == 'CR2' and dir == 'IFD0') and
                    not (matches(tf, [[^(DNG|TIFF)$]]) and perlStr(comp) == '7' and perlStr(self:FindValue('SubfileType', dir)) ~= '0') and
                    not (tf == 'APP1' and dir == 'IFD2')
            end,
            Name = 'StripOffsets',
            IsOffset = 1,
            IsImageData = 1,
            OffsetPair = 0x117,
            ValueConv = function(_self, val)
                if type(val) == 'string' and #val > 32 then
                    return { ref = 'SCALAR', value = val }
                end
                return val
            end,
        },
        {
            -- PreviewImageStart in IFD0 of CR2 images
            Condition = function(self) return self.TIFF_TYPE == 'CR2' end,
            Name = 'PreviewImageStart',
            IsOffset = 1,
            OffsetPair = 0x117,
            Notes = [[
                called StripOffsets in most locations, but it is PreviewImageStart in IFD0
                of CR2 images and various IFD's of DNG images except for SubIFD2 where it is
                JpgFromRawStart
            ]],
            DataTag = 'PreviewImage',
            Writable = 'int32u',
            WriteGroup = 'IFD0',
            Protected = 2,
            Permanent = 1,
        },
        {
            -- PreviewImageStart in various IFD's of DNG images except SubIFD2
            Condition = function(self) return self.DIR_NAME ~= 'SubIFD2' end,
            Name = 'PreviewImageStart',
            IsOffset = 1,
            OffsetPair = 0x117,
            DataTag = 'PreviewImage',
            Writable = 'int32u',
            WriteGroup = 'All',    -- (writes to specific group of associated Composite tag)
            Protected = 2,
            Permanent = 1,
        },
        {
            -- JpgFromRawStart in various IFD's of DNG images except SubIFD2
            Name = 'JpgFromRawStart',
            IsOffset = 1,
            IsImageData = 1,
            OffsetPair = 0x117,
            DataTag = 'JpgFromRaw',
            Writable = 'int32u',
            WriteGroup = 'SubIFD2',
            Protected = 2,
            Permanent = 1,
        },
    },
    [0x112] = {
        Name = 'Orientation',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        PrintConv = Exif.orientation,
        Priority = 0,
    },
    [0x115] = {
        Name = 'SamplesPerPixel',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Priority = 0,
    },
    [0x116] = {
        Name = 'RowsPerStrip',
        Protected = 1,
        Writable = 'int32u',
        WriteGroup = 'IFD0',
        Priority = 0,
    },
    [0x117] = {
        {
            Condition = function(self)
                return self.TIFF_TYPE == 'MRW' and self.DIR_NAME == 'IFD0' and
                    matches(perlStr(self.Model or ''), [[^DiMAGE A200]]) ~= nil
            end,
            Name = 'StripByteCounts',
            OffsetPair = 0x111,   -- point to associated offset
            -- A200 stores this information in the wrong byte order!!
            ValueConv = a200ValueConv,
            ByteOrder = 'LittleEndian',
        },
        {
            Condition = function(self) return compressionIs(self, '34892') end, -- DNG Lossy JPEG
            Name = 'OtherImageLength',
            OffsetPair = 0x111,   -- point to associated offset
            DataTag = 'OtherImage',
        },
        {
            Condition = function(self) return compressionIs(self, '52546') end, -- DNG 1.7 Jpeg XL
            Name = 'PreviewJXLLength',
            OffsetPair = 0x111,   -- point to associated offset
            DataTag = 'PreviewJXL',
        },
        {
            -- (APP1 IFD2 is for Leica JPEG preview)
            Condition = function(self)
                local tf = self.TIFF_TYPE
                local dir = self.DIR_NAME
                local comp = self:FindValue('Compression', dir)
                return not (tf == 'CR2' and dir == 'IFD0') and
                    not (matches(tf, [[^(DNG|TIFF)$]]) and perlStr(comp) == '7' and perlStr(self:FindValue('SubfileType', dir)) ~= '0') and
                    not (tf == 'APP1' and dir == 'IFD2')
            end,
            Name = 'StripByteCounts',
            OffsetPair = 0x111,
            ValueConv = function(_self, val)
                if type(val) == 'string' and #val > 32 then
                    return { ref = 'SCALAR', value = val }
                end
                return val
            end,
        },
        {
            -- PreviewImageLength in IFD0 of CR2 images
            Condition = function(self) return self.TIFF_TYPE == 'CR2' end,
            Name = 'PreviewImageLength',
            OffsetPair = 0x111,
            Notes = [[
                called StripByteCounts in most locations, but it is PreviewImageLength in
                IFD0 of CR2 images and various IFD's of DNG images except for SubIFD2 where
                it is JpgFromRawLength
            ]],
            DataTag = 'PreviewImage',
            Writable = 'int32u',
            WriteGroup = 'IFD0',
            Protected = 2,
            Permanent = 1,
        },
        {
            -- PreviewImageLength in various IFD's of DNG images except SubIFD2
            Condition = function(self) return self.DIR_NAME ~= 'SubIFD2' end,
            Name = 'PreviewImageLength',
            OffsetPair = 0x111,
            DataTag = 'PreviewImage',
            Writable = 'int32u',
            WriteGroup = 'All',    -- (writes to specific group of associated Composite tag)
            Protected = 2,
            Permanent = 1,
        },
        {
            -- JpgFromRawLength in SubIFD2 of DNG images
            Name = 'JpgFromRawLength',
            OffsetPair = 0x111,
            DataTag = 'JpgFromRaw',
            Writable = 'int32u',
            WriteGroup = 'SubIFD2',
            Protected = 2,
            Permanent = 1,
        },
    },
    [0x118] = {
        Name = 'MinSampleValue',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
    },
    [0x119] = {
        Name = 'MaxSampleValue',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
    },
    [0x11a] = {
        Name = 'XResolution',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Mandatory = 1,
        Priority = 0,  -- so PRIORITY_DIR takes precedence
    },
    [0x11b] = {
        Name = 'YResolution',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Mandatory = 1,
        Priority = 0,
    },
    [0x11c] = {
        Name = 'PlanarConfiguration',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        PrintConv = {
            [1] = 'Chunky',
            [2] = 'Planar',
        },
        Priority = 0,
    },
    [0x11d] = {
        Name = 'PageName',
        Writable = 'string',
        WriteGroup = 'IFD0',
    },
    [0x11e] = {
        Name = 'XPosition',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
    },
    [0x11f] = {
        Name = 'YPosition',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
    },
    -- FreeOffsets/FreeByteCounts are used by Ricoh for RMETA information
    -- in TIFF images (not yet supported)
    [0x120] = {
        Name = 'FreeOffsets',
        IsOffset = 1,
        OffsetPair = 0x121,
        ValueConv = function(_self, val)
            if type(val) == 'string' and #val > 32 then
                return { ref = 'SCALAR', value = val }
            end
            return val
        end,
    },
    [0x121] = {
        Name = 'FreeByteCounts',
        OffsetPair = 0x120,
        ValueConv = function(_self, val)
            if type(val) == 'string' and #val > 32 then
                return { ref = 'SCALAR', value = val }
            end
            return val
        end,
    },
    [0x122] = {
        Name = 'GrayResponseUnit',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        PrintConv = { --3
            [1] = 0.1,
            [2] = 0.001,
            [3] = 0.0001,
            [4] = 0.00001,
            [5] = 0.000001,
        },
    },
    [0x123] = {
        Name = 'GrayResponseCurve',
        Binary = 1,
    },
    [0x124] = {
        Name = 'T4Options',
        PrintConv = { BITMASK = {
            [0] = '2-Dimensional encoding',
            [1] = 'Uncompressed',
            [2] = 'Fill bits added',
        } }, --3
    },
    [0x125] = {
        Name = 'T6Options',
        PrintConv = { BITMASK = {
            [1] = 'Uncompressed',
        } }, --3
    },
    [0x128] = {
        Name = 'ResolutionUnit',
        Notes = 'the value 1 is not standard EXIF',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Mandatory = 1,
        PrintConv = {
            [1] = 'None',
            [2] = 'inches',
            [3] = 'cm',
        },
        Priority = 0,
    },
    [0x129] = {
        Name = 'PageNumber',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Count = 2,
    },
    [0x12c] = 'ColorResponseUnit', --9
    [0x12d] = {
        Name = 'TransferFunction',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Count = 768,
        Binary = 1,
    },
    [0x131] = {
        Name = 'Software',
        Writable = 'string',
        WriteGroup = 'IFD0',
        DataMember = 'Software',
        RawConv = function(self, val)
            val = val:gsub('[ \t\n\r\f\v]+$', '')
            self.Software = val
            return val
        end,
    },
    [0x132] = {
        Name = 'ModifyDate',
        Groups = { [2] = 'Time' },
        Notes = 'called DateTime by the EXIF spec.',
        Writable = 'string',
        Shift = 'Time',
        WriteGroup = 'IFD0',
        Validate = function(_self, val) return require('lexiftool.Validate').ValidateExifDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val, 0) end,
    },
    [0x13b] = {
        Name = 'Artist',
        Groups = { [2] = 'Author' },
        Notes = 'becomes a list-type tag when the MWG module is loaded',
        Writable = 'string',
        WriteGroup = 'IFD0',
        RawConv = function(_self, val) val = subst(val, [[\s+$]], '') return val end, -- trim trailing blanks
    },
    [0x13c] = {
        Name = 'HostComputer',
        Writable = 'string',
        WriteGroup = 'IFD0',
    },
    [0x13d] = {
        Name = 'Predictor',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        PrintConv = {
            [1] = 'None',
            [2] = 'Horizontal differencing',
            [3] = 'Floating point', -- # (DNG 1.5)
            [34892] = 'Horizontal difference X2', -- # (DNG 1.5)
            [34893] = 'Horizontal difference X4', -- # (DNG 1.5)
            [34894] = 'Floating point X2', -- # (DNG 1.5)
            [34895] = 'Floating point X4', -- # (DNG 1.5)
        },
    },
    [0x13e] = {
        Name = 'WhitePoint',
        Groups = { [2] = 'Camera' },
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Count = 2,
    },
    [0x13f] = {
        Name = 'PrimaryChromaticities',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Count = 6,
        Priority = 0,
    },
    [0x140] = {
        Name = 'ColorMap',
        Format = 'binary',
        Binary = 1,
    },
    [0x141] = {
        Name = 'HalftoneHints',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Count = 2,
    },
    [0x142] = {
        Name = 'TileWidth',
        Protected = 1,
        Writable = 'int32u',
        WriteGroup = 'IFD0',
    },
    [0x143] = {
        Name = 'TileLength',
        Protected = 1,
        Writable = 'int32u',
        WriteGroup = 'IFD0',
    },
    [0x144] = {
        Name = 'TileOffsets',
        IsOffset = 1,
        IsImageData = 1,
        OffsetPair = 0x145,
        ValueConv = function(_self, val)
            if #perlStr(val) > 32 then return { ref = 'SCALAR', value = val } end
            return val
        end,
    },
    [0x145] = {
        Name = 'TileByteCounts',
        OffsetPair = 0x144,
        ValueConv = function(_self, val)
            if #perlStr(val) > 32 then return { ref = 'SCALAR', value = val } end
            return val
        end,
    },
    [0x146] = 'BadFaxLines', --3
    [0x147] = { --3
        Name = 'CleanFaxData',
        PrintConv = {
            [0] = 'Clean',
            [1] = 'Regenerated',
            [2] = 'Unclean',
        },
    },
    [0x148] = 'ConsecutiveBadFaxLines', --3
    [0x14a] = {
        {
            Name = 'SubIFD',
            -- use this opportunity to identify an ARW image, and if so we
            -- must decide if this is a SubIFD or the A100 raw data
            -- (use SubfileType, Compression and FILE_TYPE to identify ARW/SR2,
            -- then call SetARW to finish the job)
            Condition = function(self, valPt)
                return self.DIR_NAME ~= 'IFD0' or self.FILE_TYPE ~= 'TIFF' or
                    matches(self.Make, [[^SONY]]) == nil or
                    not perlTruthy(self.SubfileType) or tonumber(self.SubfileType) ~= 1 or
                    not perlTruthy(self.Compression) or tonumber(self.Compression) ~= 6 or
                    not require('lexiftool.Sony') or
                    perlTruthy(require('lexiftool.Sony').SetARW(self, valPt))
            end,
            Groups = { [1] = 'SubIFD' },
            Flags = 'SubIFD',
            SubDirectory = {
                Start = function(_self, val, _valuePtr) return val end,
                MaxSubdirs = 10, -- (have seen 5 in a DNG 1.4 image)
            },
        },
        { -- #16
            Name = 'A100DataOffset',
            Notes = 'the data offset in original Sony DSLR-A100 ARW images',
            DataMember = 'A100DataOffset',
            RawConv = function(self, val) self.A100DataOffset = val return val end,
            WriteGroup = 'IFD0', -- (only for Validate)
            IsOffset = 1,
            Protected = 2,
        },
    },
    [0x14c] = {
        Name = 'InkSet',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        PrintConv = { --3
            [1] = 'CMYK',
            [2] = 'Not CMYK',
        },
    },
    [0x14d] = 'InkNames', --3
    [0x14e] = 'NumberofInks', --3
    [0x150] = 'DotRange', -- (int8u or int16u)
    [0x151] = {
        Name = 'TargetPrinter',
        Writable = 'string',
        WriteGroup = 'IFD0',
    },
    [0x152] = {
        Name = 'ExtraSamples',
        PrintConv = { --20
            [0] = 'Unspecified',
            [1] = 'Associated Alpha',
            [2] = 'Unassociated Alpha',
        },
    },
    [0x153] = {
        Name = 'SampleFormat',
        Notes = 'SamplesPerPixel values',
        WriteGroup = 'SubIFD', -- (only for Validate)
        PrintConvColumns = 2,
        PrintConv = { sampleFormat, sampleFormat, sampleFormat, sampleFormat },
    },
    [0x154] = 'SMinSampleValue',
    [0x155] = 'SMaxSampleValue',
    [0x156] = 'TransferRange',
    [0x157] = 'ClipPath', --3
    [0x158] = 'XClipPathUnits', --3
    [0x159] = 'YClipPathUnits', --3
    [0x15a] = { --3
        Name = 'Indexed',
        PrintConv = { [0] = 'Not indexed', [1] = 'Indexed' },
    },
    [0x15b] = {
        Name = 'JPEGTables',
        Binary = 1,
    },
    [0x15f] = { --10
        Name = 'OPIProxy',
        PrintConv = {
            [0] = 'Higher resolution image does not exist',
            [1] = 'Higher resolution image exists',
        },
    },
    -- 0x181 => 'Decode', #20 (typo! - should be 0x1b1, ref 21)
    -- 0x182 => 'DefaultImageColor', #20 (typo! - should be 0x1b2, ref 21)
    [0x190] = { --3
        Name = 'GlobalParametersIFD',
        Groups = { [1] = 'GlobParamIFD' },
        Flags = 'SubIFD',
        SubDirectory = {
            DirName = 'GlobParamIFD',
            Start = function(_self, val, _start) return val end,
            MaxSubdirs = 1,
        },
    },
    [0x191] = { --3
        Name = 'ProfileType',
        PrintConv = { [0] = 'Unspecified', [1] = 'Group 3 FAX' },
    },
    [0x192] = { --3
        Name = 'FaxProfile',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Minimal B&W lossless, S',
            [2] = 'Extended B&W lossless, F',
            [3] = 'Lossless JBIG B&W, J',
            [4] = 'Lossy color and grayscale, C',
            [5] = 'Lossless color and grayscale, L',
            [6] = 'Mixed raster content, M',
            [7] = 'Profile T', --20
            [255] = 'Multi Profiles', --20
        },
    },
    [0x193] = { --3
        Name = 'CodingMethods',
        PrintConv = { BITMASK = {
            [0] = 'Unspecified compression',
            [1] = 'Modified Huffman',
            [2] = 'Modified Read',
            [3] = 'Modified MR',
            [4] = 'JBIG',
            [5] = 'Baseline JPEG',
            [6] = 'JBIG color',
        } },
    },
    [0x194] = 'VersionYear', --3
    [0x195] = 'ModeNumber', --3
    [0x1b1] = 'Decode', --3
    [0x1b2] = 'DefaultImageColor', --3 (changed to ImageBaseColor, ref 21)
    [0x1b3] = 'T82Options', --20
    [0x1b5] = { --19
        Name = 'JPEGTables',
        Binary = 1,
    },
    [0x200] = {
        Name = 'JPEGProc',
        PrintConv = {
            [1] = 'Baseline',
            [14] = 'Lossless',
        },
    },
    [0x201] = {
        {
            Name = 'ThumbnailOffset',
            Notes = [[
                called JPEGInterchangeFormat in the specification, this is ThumbnailOffset
                in IFD1 of JPEG and some TIFF-based images, IFD0 of MRW images and AVI and
                MOV videos, and the SubIFD in IFD1 of SRW images; PreviewImageStart in
                MakerNotes and IFD0 of ARW and SR2 images; JpgFromRawStart in SubIFD of NEF
                images and IFD2 of PEF images; and OtherImageStart in everything else
            ]],
            -- thumbnail is found in IFD1 of JPEG and TIFF images, and
            -- IFD0 of EXIF information in FujiFilm AVI (RIFF) and MOV videos
            Condition = function(self)
                -- recognize NRW file from a JPEG-compressed thumbnail in IFD0
                if self.TIFF_TYPE == 'NEF' and self.DIR_NAME == 'IFD0' and self.Compression == 6 then
                    self.TIFF_TYPE = 'NRW'
                    self:OverrideFileType('NRW', 'image/x-nikon-nef')
                end
                return self.DIR_NAME == 'IFD1' or
                    (self.DIR_NAME == 'IFD0' and (self.FILE_TYPE == 'RIFF' or self.FILE_TYPE == 'MOV'))
            end,
            IsOffset = 1,
            OffsetPair = 0x202,
            DataTag = 'ThumbnailImage',
            Writable = 'int32u',
            WriteGroup = 'IFD1',
            -- according to the EXIF spec. a JPEG-compressed thumbnail image may not
            -- be stored in a TIFF file, but these TIFF-based RAW image formats
            -- use IFD1 for a JPEG-compressed thumbnail:  CR2, ARW, SR2 and PEF.
            -- (SRF also stores a JPEG image in IFD1, but it is actually a preview
            -- and we don't yet write SRF anyway)
            WriteCondition = function(self)
                return self.FILE_TYPE ~= "TIFF" or
                    isMatch(self.TIFF_TYPE, [[^(CR2|ARW|SR2|PEF)$]])
            end,
            Protected = 2,
        },
        {
            Name = 'ThumbnailOffset',
            -- thumbnail in IFD0 of MRW images (Minolta A200)
            -- and IFD0 of NRW images (Nikon Coolpix P6000,P7000,P7100)
            Condition = function(self)
                return self.DIR_NAME == 'IFD0' and (self.TIFF_TYPE == 'MRW' or self.TIFF_TYPE == 'NRW')
            end,
            IsOffset = 1,
            OffsetPair = 0x202,
            -- A200 uses the wrong base offset for this pointer!!
            WrongBase = function(self)
                if isMatch(self.Model, '^DiMAGE A200') then return self.MRW_WrongBase end
                return nil
            end,
            DataTag = 'ThumbnailImage',
            Writable = 'int32u',
            WriteGroup = 'IFD0',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'ThumbnailOffset',
            -- in SubIFD of IFD1 in Samsung SRW images
            Condition = function(self)
                return self.TIFF_TYPE == 'SRW' and self.DIR_NAME == 'SubIFD' and
                    self.PATH[#self.PATH - 1] == 'IFD1'
            end,
            IsOffset = 1,
            OffsetPair = 0x202,
            DataTag = 'ThumbnailImage',
            Writable = 'int32u',
            WriteGroup = 'SubIFD',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'PreviewImageStart',
            Condition = function(self) return self.DIR_NAME == 'MakerNotes' end,
            IsOffset = 1,
            OffsetPair = 0x202,
            DataTag = 'PreviewImage',
            Writable = 'int32u',
            WriteGroup = 'MakerNotes',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'PreviewImageStart',
            -- PreviewImage in IFD0 of ARW and SR2 files for all models
            Condition = function(self)
                return self.DIR_NAME == 'IFD0' and (self.TIFF_TYPE == 'ARW' or self.TIFF_TYPE == 'SR2')
            end,
            IsOffset = 1,
            OffsetPair = 0x202,
            DataTag = 'PreviewImage',
            Writable = 'int32u',
            WriteGroup = 'IFD0',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'JpgFromRawStart',
            Condition = function(self) return self.DIR_NAME == 'SubIFD' end,
            IsOffset = 1,
            IsImageData = 1,
            OffsetPair = 0x202,
            DataTag = 'JpgFromRaw',
            Writable = 'int32u',
            WriteGroup = 'SubIFD',
            -- JpgFromRaw is in SubIFD of NEF, NRW and SRW files
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'JpgFromRawStart',
            Condition = function(self) return self.DIR_NAME == 'IFD2' end,
            IsOffset = 1,
            IsImageData = 1,
            OffsetPair = 0x202,
            DataTag = 'JpgFromRaw',
            Writable = 'int32u',
            WriteGroup = 'IFD2',
            -- JpgFromRaw is in IFD2 of PEF files
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'OtherImageStart',
            Condition = function(self) return self.DIR_NAME == 'SubIFD1' end,
            IsImageData = 1,
            IsOffset = 1,
            OffsetPair = 0x202,
            DataTag = 'OtherImage',
            Writable = 'int32u',
            WriteGroup = 'SubIFD1',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'OtherImageStart',
            Condition = function(self) return self.DIR_NAME == 'SubIFD2' end,
            IsOffset = 1,
            IsImageData = 1,
            OffsetPair = 0x202,
            DataTag = 'OtherImage',
            Writable = 'int32u',
            WriteGroup = 'SubIFD2',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'OtherImageStart',
            IsOffset = 1,
            IsImageData = 1,
            OffsetPair = 0x202,
        },
    },
    [0x202] = {
        {
            Name = 'ThumbnailLength',
            Notes = 'called JPEGInterchangeFormatLength in the specification, this is' ..
                ' ThumbnailLength in IFD1 of JPEG and some TIFF-based images, IFD0 of MRW' ..
                ' images and AVI and MOV videos, and the SubIFD in IFD1 of SRW images;' ..
                ' PreviewImageLength in MakerNotes and IFD0 of ARW and SR2 images;' ..
                ' JpgFromRawLength in SubIFD of NEF images, and IFD2 of PEF images; and' ..
                ' OtherImageLength in everything else',
            Condition = function(self)
                return self.DIR_NAME == 'IFD1' or
                    (self.DIR_NAME == 'IFD0' and (self.FILE_TYPE == 'RIFF' or self.FILE_TYPE == 'MOV'))
            end,
            OffsetPair = 0x201,
            DataTag = 'ThumbnailImage',
            Writable = 'int32u',
            WriteGroup = 'IFD1',
            WriteCondition = function(self)
                return self.FILE_TYPE ~= "TIFF" or
                    isMatch(self.TIFF_TYPE, [[^(CR2|ARW|SR2|PEF)$]])
            end,
            Protected = 2,
        },
        {
            Name = 'ThumbnailLength',
            -- thumbnail in IFD0 of MRW images (Minolta A200)
            -- and IFD0 of NRW images (Nikon Coolpix P6000,P7000,P7100)
            Condition = function(self)
                return self.DIR_NAME == 'IFD0' and (self.TIFF_TYPE == 'MRW' or self.TIFF_TYPE == 'NRW')
            end,
            OffsetPair = 0x201,
            DataTag = 'ThumbnailImage',
            Writable = 'int32u',
            WriteGroup = 'IFD0',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'ThumbnailLength',
            -- in SubIFD of IFD1 in Samsung SRW images
            Condition = function(self)
                return self.TIFF_TYPE == 'SRW' and self.DIR_NAME == 'SubIFD' and
                    self.PATH[#self.PATH - 1] == 'IFD1'
            end,
            OffsetPair = 0x201,
            DataTag = 'ThumbnailImage',
            Writable = 'int32u',
            WriteGroup = 'SubIFD',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'PreviewImageLength',
            Condition = function(self) return self.DIR_NAME == 'MakerNotes' end,
            OffsetPair = 0x201,
            DataTag = 'PreviewImage',
            Writable = 'int32u',
            WriteGroup = 'MakerNotes',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'PreviewImageLength',
            -- PreviewImage in IFD0 of ARW and SR2 files for all models
            Condition = function(self)
                return self.DIR_NAME == 'IFD0' and (self.TIFF_TYPE == 'ARW' or self.TIFF_TYPE == 'SR2')
            end,
            OffsetPair = 0x201,
            DataTag = 'PreviewImage',
            Writable = 'int32u',
            WriteGroup = 'IFD0',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'JpgFromRawLength',
            Condition = function(self) return self.DIR_NAME == 'SubIFD' end,
            OffsetPair = 0x201,
            DataTag = 'JpgFromRaw',
            Writable = 'int32u',
            WriteGroup = 'SubIFD',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'JpgFromRawLength',
            Condition = function(self) return self.DIR_NAME == 'IFD2' end,
            OffsetPair = 0x201,
            DataTag = 'JpgFromRaw',
            Writable = 'int32u',
            WriteGroup = 'IFD2',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'OtherImageLength',
            Condition = function(self) return self.DIR_NAME == 'SubIFD1' end,
            OffsetPair = 0x201,
            DataTag = 'OtherImage',
            Writable = 'int32u',
            WriteGroup = 'SubIFD1',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'OtherImageLength',
            Condition = function(self) return self.DIR_NAME == 'SubIFD2' end,
            OffsetPair = 0x201,
            DataTag = 'OtherImage',
            Writable = 'int32u',
            WriteGroup = 'SubIFD2',
            Protected = 2,
            Permanent = 1,
        },
        {
            Name = 'OtherImageLength',
            OffsetPair = 0x201,
        },
    },
    [0x203] = 'JPEGRestartInterval',
    [0x205] = 'JPEGLosslessPredictors',
    [0x206] = 'JPEGPointTransforms',
    [0x207] = {
        Name = 'JPEGQTables',
        IsOffset = 1,
        -- this tag is not supported for writing, so define an
        -- invalid offset pair to cause a "No size tag" error to be
        -- generated if we try to write a file containing this tag
        OffsetPair = -1,
    },
    [0x208] = {
        Name = 'JPEGDCTables',
        IsOffset = 1,
        OffsetPair = -1, -- (see comment for JPEGQTables)
    },
    [0x209] = {
        Name = 'JPEGACTables',
        IsOffset = 1,
        OffsetPair = -1, -- (see comment for JPEGQTables)
    },
    [0x211] = {
        Name = 'YCbCrCoefficients',
        Protected = 1,
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Count = 3,
        Priority = 0,
    },
    [0x212] = {
        Name = 'YCbCrSubSampling',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Count = 2,
        PrintConvColumns = 2,
        PrintConv = require('lexiftool.JPEG').yCbCrSubSampling,
        Priority = 0,
    },
    [0x213] = {
        Name = 'YCbCrPositioning',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Mandatory = 1,
        PrintConv = {
          -- 0 - written by Adobe DNG converter 18.1 when converting from CR3
            [1] = 'Centered',
            [2] = 'Co-sited',
        },
        Priority = 0,
    },
    [0x214] = {
        Name = 'ReferenceBlackWhite',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Count = 6,
        Priority = 0,
    },
  -- 0x220 - int32u: 0 (IFD0, Xiaomi Redmi models)
  -- 0x221 - int32u: 0 (IFD0, Xiaomi Redmi models)
  -- 0x222 - int32u: 0 (IFD0, Xiaomi Redmi models)
  -- 0x223 - int32u: 0 (IFD0, Xiaomi Redmi models)
  -- 0x224 - int32u: 0,1 (IFD0, Xiaomi Redmi models)
  -- 0x225 - string: "" (IFD0, Xiaomi Redmi models)
    [0x22f] = 'StripRowCounts',
    [0x2bc] = {
        Name = 'ApplicationNotes', -- (writable directory!)
        Format = 'undef',
        Writable = 'int8u',
        WriteGroup = 'IFD0', -- (only for Validate)
        Flags = { 'Binary', 'Protected' },
        -- this could be an XMP block
        SubDirectory = {
            DirName = 'XMP',
            TagTable = 'lexiftool.XMP.Main',
        },
    },
    [0x303] = { --https://learn.microsoft.com/en-us/windows/win32/gdiplus/-gdiplus-constant-property-item-descriptions
        Name = 'RenderingIntent',
        Format = 'int8u',
        PrintConv = {
            [0] = 'Perceptual',
            [1] = 'Relative Colorimetric',
            [2] = 'Saturation',
            [3] = 'Absolute colorimetric',
        },
    },
    [0x3e7] = 'USPTOMiscellaneous', --20
    [0x1000] = { --5
        Name = 'RelatedImageFileFormat',
        Protected = 1,
        Writable = 'string',
        WriteGroup = 'InteropIFD',
    },
    [0x1001] = { --5
        Name = 'RelatedImageWidth',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'InteropIFD',
    },
    [0x1002] = { --5
        Name = 'RelatedImageHeight',
        Notes = 'called RelatedImageLength by the DCF spec.',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'InteropIFD',
    },
    [0x4746] = { -- #PH
        Name = 'Rating',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Avoid = 1,
    },
    [0x4747] = { -- (written by Digital Image Pro)
        Name = 'XP_DIP_XML',
        Format = 'undef',
        -- the following reference indicates this is Unicode:
        -- http://social.msdn.microsoft.com/Forums/en-US/isvvba/thread/ce6edcbb-8fc2-40c6-ad98-85f5d835ddfb
        ValueConv = function(self, val) return self:Decode(val, 'UCS2', 'II') end,
    },
    [0x4748] = {
        Name = 'StitchInfo',
        SubDirectory = {
            TagTable = 'lexiftool.Microsoft.Stitch',
            ByteOrder = 'LittleEndian', --PH (NC)
        },
    },
    [0x4749] = { --PH
        Name = 'RatingPercent',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Avoid = 1,
    },
    -- tags 0x5XXX are obscure tags defined by Microsoft:
    -- ref https://learn.microsoft.com/en-us/previous-versions/windows/embedded/ms932271(v=msdn.10)
    -- ref https://learn.microsoft.com/en-us/windows/win32/gdiplus/-gdiplus-constant-property-item-descriptions
    [0x5001] = { Name = 'ResolutionXUnit', Notes = "ID's from 0x5001 to 0x5113 are obscure tags defined by Microsoft" }, -- (int16u)
    [0x5002] = 'ResolutionYUnit', -- (int16u)
    [0x5003] = 'ResolutionXLengthUnit', -- (int16u)
    [0x5004] = 'ResolutionYLengthUnit', -- (int16u)
    [0x5005] = 'PrintFlags', -- (string)
    [0x5006] = 'PrintFlagsVersion', -- (int16u)
    [0x5007] = 'PrintFlagsCrop', -- (int8u)
    [0x5008] = 'PrintFlagsBleedWidth', -- (int32u)
    [0x5009] = 'PrintFlagsBleedWidthScale', -- (int16u)
    [0x500a] = 'HalftoneLPI', -- (rational64u)
    [0x500b] = 'HalftoneLPIUnit', -- (int16u, 1=inch, 2=cm)
    [0x500c] = 'HalftoneDegree', -- (rational64u)
    [0x500d] = 'HalftoneShape', -- (int16u,0=round,1=Ellipse,2=Line,3=Square,4=Cross,5=Diamond)
    [0x500e] = 'HalftoneMisc', -- (int32u)
    [0x500f] = 'HalftoneScreen', -- (int8u)
    [0x5010] = 'JPEGQuality', -- (int32u[N])
    [0x5011] = { Name = 'GridSize', Binary = 1 }, -- (undef)
    [0x5012] = 'ThumbnailFormat', -- (int32u,1=raw RGB,2=JPEG)
    [0x5013] = 'ThumbnailWidth', -- (int32u)
    [0x5014] = 'ThumbnailHeight', -- (int32u)
    [0x5015] = 'ThumbnailColorDepth', -- (int16u)
    [0x5016] = 'ThumbnailPlanes', -- (int16u)
    [0x5017] = 'ThumbnailRawBytes', -- (int32u)
    [0x5018] = 'ThumbnailLength', -- (int32u)
    [0x5019] = 'ThumbnailCompressedSize', -- (int32u)
    [0x501a] = { Name = 'ColorTransferFunction', Binary = 1 }, -- (undef)
    [0x501b] = { Name = 'ThumbnailData', Binary = 1, Format = 'undef' }, -- (int8u)
    [0x5020] = 'ThumbnailImageWidth', -- (int16u or int32u)
    [0x5021] = 'ThumbnailImageHeight', -- (int16u or int32u)
    [0x5022] = 'ThumbnailBitsPerSample', -- (int16u[N])
    [0x5023] = 'ThumbnailCompression', -- (int16u)
    [0x5024] = 'ThumbnailPhotometricInterp', -- (int16u)
    [0x5025] = 'ThumbnailDescription', -- (string)
    [0x5026] = 'ThumbnailEquipMake', -- (string)
    [0x5027] = 'ThumbnailEquipModel', -- (string)
    [0x5028] = 'ThumbnailStripOffsets', -- (int16u or int32u)
    [0x5029] = 'ThumbnailOrientation', -- (int16u)
    [0x502a] = 'ThumbnailSamplesPerPixel', -- (int16u)
    [0x502b] = 'ThumbnailRowsPerStrip', -- (int16u or int32u)
    [0x502c] = 'ThumbnailStripByteCounts', -- (int16u or int32u)
    [0x502d] = 'ThumbnailResolutionX',
    [0x502e] = 'ThumbnailResolutionY',
    [0x502f] = 'ThumbnailPlanarConfig', -- (int16u)
    [0x5030] = 'ThumbnailResolutionUnit', -- (int16u)
    [0x5031] = 'ThumbnailTransferFunction', -- (int16u[N])
    [0x5032] = 'ThumbnailSoftware', -- (string)
    [0x5033] = { Name = 'ThumbnailDateTime', Groups = { [2] = 'Time' } }, -- (string)
    [0x5034] = 'ThumbnailArtist', -- (string)
    [0x5035] = 'ThumbnailWhitePoint', -- (rational64u[2])
    [0x5036] = 'ThumbnailPrimaryChromaticities', -- (rational64u[6])
    [0x5037] = 'ThumbnailYCbCrCoefficients', -- (rational64u[3])
    [0x5038] = 'ThumbnailYCbCrSubsampling', -- (int16u)
    [0x5039] = 'ThumbnailYCbCrPositioning', -- (int16u)
    [0x503a] = 'ThumbnailRefBlackWhite', -- (rational64u[6])
    [0x503b] = 'ThumbnailCopyright', -- (string)
    [0x5090] = 'LuminanceTable', -- (int16u[64])
    [0x5091] = 'ChrominanceTable', -- (int16u[64])
    [0x5100] = 'FrameDelay', -- (int32u[N])
    [0x5101] = 'LoopCount', -- (int16u)
    [0x5102] = 'GlobalPalette', -- (int8u[N])
    [0x5103] = 'IndexBackground', -- (int8u)
    [0x5104] = 'IndexTransparent', -- (int8u)
    [0x5110] = 'PixelUnits', -- (int8u)
    [0x5111] = 'PixelsPerUnitX', -- (int32u)
    [0x5112] = 'PixelsPerUnitY', -- (int32u)
    [0x5113] = 'PaletteHistogram', -- (int8u[N])
    [0x7000] = { --JR
        Name = 'SonyRawFileType',
        -- (only valid if Sony:FileFormat >= ARW 2.0, ref IB)
        -- Writable => 'int16u', (don't allow writes for now)
        PrintConv = {
            [0] = 'Sony Uncompressed 14-bit RAW',
            [1] = 'Sony Uncompressed 12-bit RAW', --IB
            [2] = 'Sony Compressed RAW', -- (lossy, ref IB)
            [3] = 'Sony Lossless Compressed RAW', --IB
            [4] = 'Sony Lossless Compressed RAW 2', --JR (ILCE-1)
            [6] = 'Sony Compressed RAW 2', -- ILCE-7M5
        },
    },
    -- 0x7001 - int16u[1] (in SubIFD of Sony ARW images) - values: 0,1
    [0x7010] = { --IB
        Name = 'SonyToneCurve',
        -- int16u[4] (in SubIFD of Sony ARW images -- don't allow writes for now)
        -- - only the middle 4 points are stored (lower comes from black level,
        --   and upper from data maximum)
    },
    -- 0x7011 - int16u[4] (in SubIFD of Sony ARW images) - values: "0 4912 8212 12287","4000 7200 10050 12075"
    -- 0x7020 - int32u[1] (in SubIFD of Sony ARW images) - values: 0,3
    [0x7031] = {
        Name = 'VignettingCorrection',
        Notes = 'found in Sony ARW images',
        Writable = 'int16s',
        WriteGroup = 'SubIFD',
        Permanent = 1,
        Protected = 1,
        PrintConv = {
            [256] = 'Off',
            [257] = 'Auto',
            [272] = 'Auto (ILCE-1)', --JR
            [511] = 'No correction params available',
        },
    },
    [0x7032] = {
        Name = 'VignettingCorrParams', --forum7640
        Notes = 'found in Sony ARW images',
        Writable = 'int16s',
        WriteGroup = 'SubIFD',
        Count = 17,
        Permanent = 1,
        Protected = 1,
    },
    [0x7034] = {
        Name = 'ChromaticAberrationCorrection',
        Notes = 'found in Sony ARW images',
        Writable = 'int16s',
        WriteGroup = 'SubIFD',
        Permanent = 1,
        Protected = 1,
        PrintConv = {
            [0] = 'Off',
            [1] = 'Auto',
            [255] = 'No correction params available',
        },
    },
    [0x7035] = {
        Name = 'ChromaticAberrationCorrParams', --forum6509
        Notes = 'found in Sony ARW images',
        Writable = 'int16s',
        WriteGroup = 'SubIFD',
        Count = 33,
        Permanent = 1,
        Protected = 1,
    },
    [0x7036] = {
        Name = 'DistortionCorrection',
        Notes = 'found in Sony ARW images',
        Writable = 'int16s',
        WriteGroup = 'SubIFD',
        Permanent = 1,
        Protected = 1,
        PrintConv = {
            [0] = 'Off',
            [1] = 'Auto',
            [17] = 'Auto fixed by lens',
            [255] = 'No correction params available',
        },
    },
    [0x7037] = {
        Name = 'DistortionCorrParams', --forum6509
        Notes = 'found in Sony ARW images',
        Writable = 'int16s',
        WriteGroup = 'SubIFD',
        Count = 17,
        Permanent = 1,
        Protected = 1,
    },
    [0x7038] = { --github#195 (Sony ARW)
        Name = 'SonyRawImageSize',
        Notes = 'size of actual image in Sony ARW files',
        Writable = 'int32u',
        WriteGroup = 'SubIFD',
        Count = 2,
        Permanent = 1,
        Protected = 1,
    },
    [0x7310] = { --github#195 (Sony ARW)
        Name = 'BlackLevel',
        Notes = 'found in Sony ARW images',
        Writable = 'int16u',
        WriteGroup = 'SubIFD',
        Count = 4,
        Permanent = 1,
        Protected = 1,
    },
    [0x7313] = { --github#195 (Sony ARW)
        Name = 'WB_RGGBLevels',
        Notes = 'found in Sony ARW images',
        Writable = 'int16s',
        WriteGroup = 'SubIFD',
        Count = 4,
        Permanent = 1,
        Protected = 1,
    },
    [0x74c7] = { --IB (in ARW images from some Sony cameras)
        Name = 'SonyCropTopLeft',
        Writable = 'int32u',
        WriteGroup = 'SubIFD',
        Count = 2,
        Permanent = 1,
        Protected = 1,
    },
    [0x74c8] = { --IB (in ARW images from some Sony cameras)
        Name = 'SonyCropSize',
        Writable = 'int32u',
        WriteGroup = 'SubIFD',
        Count = 2,
        Permanent = 1,
        Protected = 1,
    },
    [0x800d] = 'ImageID', --10
    [0x80a3] = { Name = 'WangTag1', Binary = 1 }, --20
    [0x80a4] = { Name = 'WangAnnotation', Binary = 1 },
    [0x80a5] = { Name = 'WangTag3', Binary = 1 }, --20
    [0x80a6] = { --20
        Name = 'WangTag4',
        PrintConv = function(_self, val)
            if type(val) == 'string' and #val > 64 then
                return { ref = 'SCALAR', value = val }
            end
            return val
        end,
    },
    -- tags 0x80b8-0x80bc are registered to Island Graphics
    [0x80b9] = 'ImageReferencePoints', --29
    [0x80ba] = 'RegionXformTackPoint', --29
    [0x80bb] = 'WarpQuadrilateral', --29
    [0x80bc] = 'AffineTransformMat', --29
    [0x80e3] = 'Matteing', --9
    [0x80e4] = 'DataType', --9
    [0x80e5] = 'ImageDepth', --9
    [0x80e6] = 'TileDepth', --9
    -- tags 0x8214-0x8219 are registered to Pixar
    [0x8214] = 'ImageFullWidth', --29
    [0x8215] = 'ImageFullHeight', --29
    [0x8216] = 'TextureFormat', --29
    [0x8217] = 'WrapModes', --29
    [0x8218] = 'FovCot', --29
    [0x8219] = 'MatrixWorldToScreen', --29
    [0x821a] = 'MatrixWorldToCamera', --29
    [0x827d] = 'Model2', --29 (Eastman Kodak)
    [0x828d] = { -- #12
        Name = 'CFARepeatPatternDim',
        Protected = 1,
        Writable = 'int16u',
        WriteGroup = 'SubIFD',
        Count = 2,
    },
    [0x828e] = {
        Name = 'CFAPattern2', -- #12
        Format = 'int8u', -- (written incorrectly as 'undef' in Nikon NRW images)
        Protected = 1,
        Writable = 'int8u',
        WriteGroup = 'SubIFD',
        Count = -1,
    },
    [0x828f] = { --12
        Name = 'BatteryLevel',
        Groups = { [2] = 'Camera' },
    },
    [0x8290] = {
        Name = 'KodakIFD',
        Groups = { [1] = 'KodakIFD' },
        Flags = 'SubIFD',
        Notes = 'used in various types of Kodak images',
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.IFD',
            DirName = 'KodakIFD',
            Start = function(_self, val, _start) return val end,
            MaxSubdirs = 1,
        },
    },
    [0x8298] = {
        Name = 'Copyright',
        Groups = { [2] = 'Author' },
        Format = 'undef',
        Writable = 'string',
        WriteGroup = 'IFD0',
        Notes = [[
            may contain copyright notices for photographer and editor, separated by a
            newline.  As per the EXIF specification, the newline is replaced by a null
            byte when writing to file, but this may be avoided by disabling the print
            conversion
        ]],
        -- internally the strings are separated by a null character in this format:
        -- Photographer only: photographer + NULL
        -- Both:              photographer + NULL + editor + NULL
        -- Editor only:       SPACE + NULL + editor + NULL
        -- (this is done as a RawConv so conditional replaces will work properly)
        RawConv = function(self, val)
            val = val:gsub(' *\0', '\n', 1)  -- translate first NULL to a newline, removing trailing blanks
            val = val:gsub(' *\0.*', '')      -- truncate at second NULL and remove trailing blanks
            val = val:gsub('\n$', '')         -- remove trailing newline if it exists
            -- decode if necessary (note: this is the only non-'string' EXIF value like this)
            local enc = self:Options('CharsetEXIF')
            if ExifTool.perlTruthy(enc) then val = self:Decode(val, enc) end
            return val
        end,
        -- (upstream RawConvInv: `$val . "\0"` -- null-terminate, since the
        --  Format is 'undef' so WriteValue does not null-terminate it)
        RawConvInv = function(_self, val) return perlStr(val) .. '\0' end,
        -- (upstream PrintConvInv: translate a newline back to the null
        --  separator, ' ' for a missing photographer)
        PrintConvInv = function(self, val)
            -- encode if necessary (not automatic because Format is 'undef')
            local enc = self:Options('CharsetEXIF')
            if enc and not val:find('\0', 1, true) then val = self:Encode(val, enc) end
            local p1, p2 = val:match('^(.-)[ \t\n\r\f\v]*[\r\n][ \t\n\r\f\v]*(.*)$')
            if p1 then
                if p2 == '' then return p1 end
                return (p1 ~= '' and p1 or ' ') .. '\0' .. p2
            end
            return val
        end,
    },
    [0x829a] = {
        Name = 'ExposureTime',
        Writable = 'rational64u',
        PrintConv = function(_self, val) return PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x829d] = {
        Name = 'FNumber',
        Writable = 'rational64u',
        PrintConv = function(_self, val) return PrintFNumber(val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x82a5] = { --3
        Name = 'MDFileTag',
        Notes = 'tags 0x82a5-0x82ac are used in Molecular Dynamics GEL files',
    },
    [0x82a6] = 'MDScalePixel', --3
    [0x82a7] = 'MDColorTable', --3
    [0x82a8] = 'MDLabName', --3
    [0x82a9] = 'MDSampleInfo', --3
    [0x82aa] = 'MDPrepDate', --3
    [0x82ab] = 'MDPrepTime', --3
    [0x82ac] = 'MDFileUnits', --3
    [0x830e] = { -- #30 (GeoTiff)
        Name = 'PixelScale',
        Writable = 'double',
        WriteGroup = 'IFD0',
        Count = 3,
    },
    [0x8335] = 'AdventScale', --20
    [0x8336] = 'AdventRevision', --20
    [0x835c] = 'UIC1Tag', --23
    [0x835d] = 'UIC2Tag', --23
    [0x835e] = 'UIC3Tag', --23
    [0x835f] = 'UIC4Tag', --23
    [0x83bb] = { -- #12
        Name = 'IPTC-NAA', -- # (writable directory! -- but see note below)
        -- this should actually be written as 'undef' (see
        -- http://www.awaresystems.be/imaging/tiff/tifftags/iptc.html),
        -- but Photoshop writes it as int32u and Nikon Capture won't read
        -- anything else, so we do the same thing here...  Doh!
        Format = 'undef', -- convert binary values as undef
        Writable = 'int32u', -- but write int32u format code in IFD
        WriteGroup = 'IFD0',
        Flags = { 'Binary', 'Protected' },
        SubDirectory = {
            DirName = 'IPTC',
            TagTable = 'lexiftool.IPTC.Main',
        },
        -- Note: This directory may be written as a block via the IPTC-NAA tag,
        -- but this technique is not recommended.  Instead, it is better to
        -- write the Extra IPTC tag and let ExifTool decide where it should go.
    },
    [0x847e] = 'IntergraphPacketData', --3
    [0x847f] = 'IntergraphFlagRegisters', --3
    [0x8480] = { --30 (GeoTiff, obsolete)
        Name = 'IntergraphMatrix',
        Writable = 'double',
        WriteGroup = 'IFD0',
        Count = -1,
    },
    [0x8481] = 'INGRReserved', --20
    [0x8482] = { -- #30 (GeoTiff)
        Name = 'ModelTiePoint',
        Groups = { [2] = 'Location' },
        Writable = 'double',
        WriteGroup = 'IFD0',
        Count = -1,
    },
    [0x84e0] = 'Site', --9
    [0x84e1] = 'ColorSequence', --9
    [0x84e2] = 'IT8Header', --9
    [0x84e3] = { --9
        Name = 'RasterPadding',
        PrintConv = { --20
            [0] = 'Byte',
            [1] = 'Word',
            [2] = 'Long Word',
            [9] = 'Sector',
            [10] = 'Long Sector',
        },
    },
    [0x84e4] = 'BitsPerRunLength', --9
    [0x84e5] = 'BitsPerExtendedRunLength', --9
    [0x84e6] = 'ColorTable', --9
    [0x84e7] = { --9
        Name = 'ImageColorIndicator',
        PrintConv = { --20
            [0] = 'Unspecified Image Color',
            [1] = 'Specified Image Color',
        },
    },
    [0x84e8] = { --9
        Name = 'BackgroundColorIndicator',
        PrintConv = { --20
            [0] = 'Unspecified Background Color',
            [1] = 'Specified Background Color',
        },
    },
    [0x84e9] = 'ImageColorValue', --9
    [0x84ea] = 'BackgroundColorValue', --9
    [0x84eb] = 'PixelIntensityRange', --9
    [0x84ec] = 'TransparencyIndicator', --9
    [0x84ed] = 'ColorCharacterization', --9
    [0x84ee] = { --9
        Name = 'HCUsage',
        PrintConv = { --20
            [0] = 'CT',
            [1] = 'Line Art',
            [2] = 'Trap',
        },
    },
    [0x84ef] = 'TrapIndicator', --17
    [0x84f0] = 'CMYKEquivalent', --17
    [0x8546] = { --11
        Name = 'SEMInfo',
        Notes = 'found in some scanning electron microscope images',
        Writable = 'string',
        WriteGroup = 'IFD0',
    },
    [0x8568] = {
        Name = 'AFCP_IPTC',
        SubDirectory = {
            -- must change directory name so we don't create this directory
            DirName = 'AFCP_IPTC',
            TagTable = 'lexiftool.IPTC.Main',
        },
    },
    [0x85b8] = 'PixelMagicJBIGOptions', --20
    [0x85d7] = 'JPLCartoIFD', --exifprobe (NC)
    [0x85d8] = { -- #30 (GeoTiff)
        Name = 'ModelTransform',
        Groups = { [2] = 'Location' },
        Writable = 'double',
        WriteGroup = 'IFD0',
        Count = 16,
    },
    [0x8602] = { -- #16
        Name = 'WB_GRGBLevels',
        Notes = 'found in IFD0 of Leaf MOS images',
    },
    -- 0x8603 - Leaf CatchLight color matrix (ref 16)
    [0x8606] = {
        Name = 'LeafData',
        Format = 'undef',    -- avoid converting huge block to string of int8u's!
        SubDirectory = {
            DirName = 'LeafIFD',
            TagTable = 'lexiftool.Leaf.Main',
        },
    },
    [0x8649] = { -- #19
        Name = 'PhotoshopSettings',
        Format = 'binary',
        WriteGroup = 'IFD0', -- (only for Validate)
        SubDirectory = {
            DirName = 'Photoshop',
            TagTable = 'lexiftool.Photoshop.Main',
        },
    },
    [0x8769] = {
        Name = 'ExifOffset',
        Groups = { [1] = 'ExifIFD' },
        WriteGroup = 'IFD0',
        SubIFD = 2,
        SubDirectory = {
            DirName = 'ExifIFD',
            Start = function(_self, val, _valuePtr) return val end,
        },
    },
    [0x8773] = {
        Name = 'ICC_Profile',
        WriteGroup = 'IFD0', -- (only for Validate)
        SubDirectory = {
            TagTable = 'lexiftool.ICC_Profile.Main',
        },
    },
    [0x877f] = { --20
        Name = 'TIFF_FXExtensions',
        PrintConv = { BITMASK = {
            [0] = 'Resolution/Image Width',
            [1] = 'N Layer Profile M',
            [2] = 'Shared Data',
            [3] = 'B&W JBIG2',
            [4] = 'JBIG2 Profile M',
        } },
    },
    [0x8780] = { --20
        Name = 'MultiProfiles',
        PrintConv = { BITMASK = {
            [0] = 'Profile S',
            [1] = 'Profile F',
            [2] = 'Profile J',
            [3] = 'Profile C',
            [4] = 'Profile L',
            [5] = 'Profile M',
            [6] = 'Profile T',
            [7] = 'Resolution/Image Width',
            [8] = 'N Layer Profile M',
            [9] = 'Shared Data',
            [10] = 'JBIG2 Profile M',
        } },
    },
    [0x8781] = { --22
        Name = 'SharedData',
        IsOffset = 1,
        -- this tag is not supported for writing, so define an
        -- invalid offset pair to cause a "No size tag" error to be
        -- generated if we try to write a file containing this tag
        OffsetPair = -1,
    },
    [0x8782] = 'T88Options', --20
    [0x87ac] = 'ImageLayer', -- Defined in the Mixed Raster Content part of RFC 2301
    [0x87af] = { --30
        Name = 'GeoTiffDirectory',
        Format = 'undef',
        Writable = 'int16u',
        Notes = [[
            these "GeoTiff" tags may read and written as a block, but they aren't
            extracted unless specifically requested.  Byte order changes are handled
            automatically when copying between TIFF images with different byte order
        ]],
        WriteGroup = 'IFD0',
        Binary = 1,
        RawConv = function(_self, val) return val .. ExifTool.GetByteOrder() end, -- save byte order
        -- swap byte order if necessary
        RawConvInv = function(_self, val)
            if #val < 2 then return val end
            local order = substr(val, -2)
            if not (order == 'II' or order == 'MM') then return val end
            val = substr(val, 0, -2)
            if order == ExifTool.GetByteOrder() then return val end
            return perl.pack('v*', unpack_('n*', val))
        end,
    },
    [0x87b0] = { --30
        Name = 'GeoTiffDoubleParams',
        Format = 'undef',
        Writable = 'double',
        WriteGroup = 'IFD0',
        Binary = 1,
        RawConv = function(_self, val) return val .. ExifTool.GetByteOrder() end, -- save byte order
        -- swap byte order if necessary
        RawConvInv = function(_self, val)
            if #val < 2 then return val end
            local order = substr(val, -2)
            if not (order == 'II' or order == 'MM') then return val end
            val = substr(val, 0, -2)
            if order == ExifTool.GetByteOrder() then return val end
            val = subst(val, [[(?s)(.{4})(.{4})]], '$2$1', 'g') -- swap words
            return perl.pack('V*', unpack_('N*', val))
        end,
    },
    [0x87b1] = { --30
        Name = 'GeoTiffAsciiParams',
        Format = 'undef',
        Writable = 'string',
        WriteGroup = 'IFD0',
        Binary = 1,
    },
    [0x87be] = 'JBIGOptions', --29
    [0x8822] = {
        Name = 'ExposureProgram',
        Groups = { [2] = 'Camera' },
        Notes = 'the value of 9 is not standard EXIF, but is used by some Canon models',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Not Defined',
            [1] = 'Manual',
            [2] = 'Program AE',
            [3] = 'Aperture-priority AE',
            [4] = 'Shutter speed priority AE',
            [5] = 'Creative (Slow speed)',
            [6] = 'Action (High speed)',
            [7] = 'Portrait',
            [8] = 'Landscape',
            [9] = 'Bulb', -- #25
        },
    },
    [0x8824] = {
        Name = 'SpectralSensitivity',
        Groups = { [2] = 'Camera' },
        Writable = 'string',
    },
    [0x8825] = {
        Name = 'GPSInfo',
        Groups = { [1] = 'GPS' },
        WriteGroup = 'IFD0', -- (only for Validate)
        Flags = 'SubIFD',
        SubDirectory = {
            DirName = 'GPS',
            TagTable = 'lexiftool.GPS.Main',
            Start = function(_self, val, _valuePtr) return val end,
            MaxSubdirs = 1,
        },
    },
    [0x8827] = {
        Name = 'ISO',
        Notes = [[
            called ISOSpeedRatings by EXIF 2.2, then PhotographicSensitivity by EXIF
            2.3.  This tag has a maximum value of 65535 because the brain-dead EXIF
            specification limits it to a short integer, and while they can change the
            name of the tag in an updated EXIF specification, they can't allow a larger
            storage format for some reason.  For higher ISO settings, see the other
            ISO-related tags StandardOutputSensitivity, RecommendedExposureIndex,
            ISOSpeed, ISOSpeedLatitudeyyy and ISOSpeedLatitudezzz.  But the meanings of
            these new tags are anyone's guess since the defining specification, ISO
            12232, is imprisoned by the ISO organization who extort a ransom for the
            release of this information
        ]],
        Writable = 'int16u',
        Count = -1,
        PrintConv = function(_self, val) val = subst(val, [[\s+]], ', ', 'g') return val end,
        PrintConvInv = function(_self, val) return (tr(val, ',', '', 'd')) end,
    },
    [0x8828] = {
        Name = 'Opto-ElectricConvFactor',
        Notes = 'called OECF by the EXIF spec.',
        Binary = 1,
    },
    [0x8829] = 'Interlace', --12
    [0x882a] = { --12
        Name = 'TimeZoneOffset',
        Writable = 'int16s',
        Count = -1, -- can be 1 or 2
        Notes = [[
            1 or 2 values: 1. The time zone offset of DateTimeOriginal from GMT in
            hours, 2. If present, the time zone offset of ModifyDate
        ]],
    },
    [0x882b] = { --12
        Name = 'SelfTimerMode',
        Writable = 'int16u',
    },
    [0x8830] = { --#24
        Name = 'SensitivityType',
        Notes = 'applies to EXIF:ISO tag',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Standard Output Sensitivity',
            [2] = 'Recommended Exposure Index',
            [3] = 'ISO Speed',
            [4] = 'Standard Output Sensitivity and Recommended Exposure Index',
            [5] = 'Standard Output Sensitivity and ISO Speed',
            [6] = 'Recommended Exposure Index and ISO Speed',
            [7] = 'Standard Output Sensitivity, Recommended Exposure Index and ISO Speed',
        },
    },
    [0x8831] = { Name = 'StandardOutputSensitivity', Writable = 'int32u' }, --#24
    [0x8832] = { Name = 'RecommendedExposureIndex', Writable = 'int32u' }, --#24
    [0x8833] = { Name = 'ISOSpeed', Writable = 'int32u' }, --#24
    [0x8834] = { Name = 'ISOSpeedLatitudeyyy', Description = 'ISO Speed Latitude yyy', Writable = 'int32u' }, --#24
    [0x8835] = { Name = 'ISOSpeedLatitudezzz', Description = 'ISO Speed Latitude zzz', Writable = 'int32u' }, --#24
    [0x885c] = 'FaxRecvParams', --9
    [0x885d] = 'FaxSubAddress', --9
    [0x885e] = 'FaxRecvTime', --9
    [0x8871] = 'FedexEDR', --exifprobe (NC)
    [0x888a] = { -- #PH
        Name = 'LeafSubIFD',
        Format = 'int32u',     -- Leaf incorrectly uses 'undef' format!
        Groups = { [1] = 'LeafSubIFD' },
        Flags = 'SubIFD',
        SubDirectory = {
            TagTable = 'lexiftool.Leaf.SubIFD',
            Start = function(_self, val, _valuePtr) return val end,
        },
    },
    [0x9000] = {
        Name = 'ExifVersion',
        Writable = 'undef',
        Mandatory = 1,
        RawConv = function(_self, val) val = subst(val, [[\0+$]], '') return val end, -- (some idiots add null terminators)
        -- (allow strings like "2.31" when writing)
        PrintConvInv = function(_self, val)
            val = tr(val, '.', '', 'd')
            if perl.isMatch(val, [[^\d{4}$]]) then return val end
            if perl.isMatch(val, [[^\d{3}$]]) then return '0' .. val end
            return nil
        end,
    },
    [0x9003] = {
        Name = 'DateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        Notes = 'date/time when original image was taken',
        Writable = 'string',
        Shift = 'Time',
        Validate = function(_self, val) return require('lexiftool.Validate').ValidateExifDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val, 0) end,
    },
    [0x9004] = {
        Name = 'CreateDate',
        Groups = { [2] = 'Time' },
        Notes = 'called DateTimeDigitized by the EXIF spec.',
        Writable = 'string',
        Shift = 'Time',
        Validate = function(_self, val) return require('lexiftool.Validate').ValidateExifDate(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val, 0) end,
    },
    [0x9009] = { -- undef[44] (or undef[11]) written by Google Plus uploader - PH
        Name = 'GooglePlusUploadCode',
        Format = 'int8u',
        Writable = 'undef',
        Count = -1,
    },
    [0x9010] = {
        Name = 'OffsetTime',
        Groups = { [2] = 'Time' },
        Notes = 'time zone for ModifyDate',
        Writable = 'string',
        Shift = 'Time',
        PrintConvInv = function(self, val) return require('lexiftool.WriteExif').InverseOffsetTime(self, val) end,
    },
    [0x9011] = {
        Name = 'OffsetTimeOriginal',
        Groups = { [2] = 'Time' },
        Notes = 'time zone for DateTimeOriginal',
        Writable = 'string',
        Shift = 'Time',
        PrintConvInv = function(self, val) return require('lexiftool.WriteExif').InverseOffsetTime(self, val) end,
    },
    [0x9012] = {
        Name = 'OffsetTimeDigitized',
        Groups = { [2] = 'Time' },
        Notes = 'time zone for CreateDate',
        Writable = 'string',
        Shift = 'Time',
        PrintConvInv = function(self, val) return require('lexiftool.WriteExif').InverseOffsetTime(self, val) end,
    },
    [0x9101] = {
        Name = 'ComponentsConfiguration',
        Format = 'int8u',
        Protected = 1,
        Writable = 'undef',
        Count = 4,
        Mandatory = 1,
        ValueConvInv = function(_self, val) return (tr(val, ',', '', 'd')) end,  -- (so we can copy from XMP with -n)
        PrintConvColumns = 2,
        PrintConv = {
            [0] = '-',
            [1] = 'Y',
            [2] = 'Cb',
            [3] = 'Cr',
            [4] = 'R',
            [5] = 'G',
            [6] = 'B',
            OTHER = function(val, inv, conv)
                local a = split([[,?\s+]], perlStr(val))
                if inv then
                    local invConv = {}
                    for k, v in pairs(conv) do
                        if type(v) == 'string' then invConv[lc(v)] = k end
                    end
                    -- strings like "YCbCr" and "RGB" still work for writing
                    if #a == 1 then a = findAll(a[1], [[(Y|Cb|Cr|R|G|B)]]) end
                    for i = 1, #a do
                        a[i] = invConv[lc(a[i])]
                        if a[i] == nil then return nil end
                    end
                    while #a < 4 do a[#a + 1] = 0 end
                else
                    for i = 1, #a do
                        -- (Lua: the lookup is keyed by number, Perl's by string)
                        a[i] = conv[tonumber(a[i]) or a[i]] or ('Err (' .. a[i] .. ')')
                    end
                end
                return table.concat(a, ', ')
            end,
        },
    },
    [0x9102] = {
        Name = 'CompressedBitsPerPixel',
        Protected = 1,
        Writable = 'rational64u',
    },
    [0x9201] = {
        Name = 'ShutterSpeedValue',
        Notes = 'displayed in seconds, but stored as an APEX value',
        Format = 'rational64s', -- Leica M8 patch (incorrectly written as rational64u)
        Writable = 'rational64s',
        ValueConv = function(_self, val)
            return ExifTool.IsFloat(val) and math.abs(val) < 100 and 2 ^ (-val) or 0
        end,
        -- ValueConvInv => '$val>0 ? -log($val)/log(2) : -100' -- inverse of
        -- ValueConv above, turning a displayed number of seconds back into
        -- the stored APEX value.
        ValueConvInv = function(_self, val)
            val = tonumber(val) or 0
            if val > 0 then return -math.log(val) / math.log(2) end
            return -100
        end,
        PrintConv = function(_self, val) return PrintExposureTime(val) end,
        PrintConvInv = function(_self, val) return ConvertFraction(val) end,
    },
    [0x9202] = {
        Name = 'ApertureValue',
        Notes = 'displayed as an F number, but stored as an APEX value',
        Writable = 'rational64u',
        ValueConv = function(_self, val) return 2 ^ (perl.num(val, '/') / 2) end,
        ValueConvInv = function(_self, val) val = tonumber(val) if val and val > 0 then return 2 * math.log(val) / math.log(2) end return 0 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x9203] = {
        Name = 'BrightnessValue',
        Writable = 'rational64s',
    },
    [0x9204] = {
        Name = 'ExposureCompensation',
        Format = 'rational64s', -- Leica M8 patch (incorrectly written as rational64u)
        Notes = 'called ExposureBiasValue by the EXIF spec.',
        Writable = 'rational64s',
        PrintConv = function(_self, val) return PrintFraction(val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x9205] = {
        Name = 'MaxApertureValue',
        Notes = 'displayed as an F number, but stored as an APEX value',
        Groups = { [2] = 'Camera' },
        Writable = 'rational64u',
        ValueConv = function(_self, val) return 2 ^ (perl.num(val, '/') / 2) end,
        ValueConvInv = function(_self, val) val = tonumber(val) if val and val > 0 then return 2 * math.log(val) / math.log(2) end return 0 end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0x9206] = {
        Name = 'SubjectDistance',
        Groups = { [2] = 'Camera' },
        Writable = 'rational64u',
        PrintConv = function(self, val)
            if perlStr(val) == 'inf' or perlStr(val) == 'undef' then return val end
            return self.NumStr(val) .. ' m'
        end,
        PrintConvInv = function(_self, val) return (subst(val, [[\s*m$]], '')) end,
    },
    [0x9207] = {
        Name = 'MeteringMode',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Average',
            [2] = 'Center-weighted average',
            [3] = 'Spot',
            [4] = 'Multi-spot',
            [5] = 'Multi-segment',
            [6] = 'Partial',
            [255] = 'Other',
        },
    },
    [0x9208] = {
        Name = 'LightSource',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        SeparateTable = 'LightSource',
        PrintConv = lightSource,
    },
    [0x9209] = {
        Name = 'Flash',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        Flags = 'PrintHex',
        SeparateTable = 'Flash',
        PrintConv = flash,
    },
    [0x920a] = {
        Name = 'FocalLength',
        Groups = { [2] = 'Camera' },
        Writable = 'rational64u',
        PrintConv = function(_self, val) return sprintf('%.1f mm', val) end,
        PrintConvInv = function(_self, val) return (subst(val, [[\s*mm$]], '')) end,
    },
    -- Note: tags 0x920b-0x9217 are duplicates of 0xa20b-0xa217
    -- (The EXIF standard uses 0xa2xx, but you'll find both in images)
    [0x920b] = { --12
        Name = 'FlashEnergy',
        Groups = { [2] = 'Camera' },
    },
    [0x920c] = 'SpatialFrequencyResponse', --12 (not in Fuji images - PH)
    [0x920d] = 'Noise', -- (FujiFilm images use this legacy tag ID instead of 0xa20d)
    [0x920e] = 'FocalPlaneXResolution', --12
    [0x920f] = 'FocalPlaneYResolution', --12
    [0x9210] = { --12
        Name = 'FocalPlaneResolutionUnit',
        Groups = { [2] = 'Camera' },
        PrintConv = {
            [1] = 'None',
            [2] = 'inches',
            [3] = 'cm',
            [4] = 'mm',
            [5] = 'um',
        },
    },
    [0x9211] = { -- #12
        Name = 'ImageNumber',
        Writable = 'int32u',
    },
    [0x9212] = { --12
        Name = 'SecurityClassification',
        Writable = 'string',
        PrintConv = {
            T = 'Top Secret',
            S = 'Secret',
            C = 'Confidential',
            R = 'Restricted',
            U = 'Unclassified',
        },
    },
    [0x9213] = { --12
        Name = 'ImageHistory',
        Writable = 'string',
    },
    [0x9214] = {
        Name = 'SubjectArea',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        Count = -1, -- 2, 3 or 4 values
    },
    [0x9215] = 'ExposureIndex', -- #12
    [0x9216] = {
        Name = 'TIFF-EPStandardID',
        PrintConv = function(_self, val) return val:gsub(' ', '.') end, -- #12
    },
    [0x9217] = { --12
        Name = 'SensingMethod',
        Groups = { [2] = 'Camera' },
        PrintConv = {
            -- (values 1 and 6 are not used by corresponding EXIF tag 0xa217)
            [1] = 'Monochrome area',
            [2] = 'One-chip color area',
            [3] = 'Two-chip color area',
            [4] = 'Three-chip color area',
            [5] = 'Color sequential area',
            [6] = 'Monochrome linear',
            [7] = 'Trilinear',
            [8] = 'Color sequential linear',
        },
    },
    [0x923a] = 'CIP3DataFile', --20
    [0x923b] = 'CIP3Sheet', --20
    [0x923c] = 'CIP3Side', --20
    [0x923f] = 'StoNits', --9
    -- handle maker notes as a conditional list
    [0x927c] = MakerNotes.Main,
    [0x9286] = {
        Name = 'UserComment',
        -- I have seen other applications write it incorrectly as 'string' or 'int8u'
        Format = 'undef',
        Writable = 'undef',
        RawConv = function(self, val) return ConvertExifText(self, val, '1', 'UserComment') end,
        RawConvInv = function(self, val) return require('lexiftool.WriteExif').EncodeExifText(self, val) end,
    },
    [0x9287] = { --Exif3.1
        Name = 'LearningOptOutIn',
        Writable = 'undef',
        Format = 'int16u',
        Notes = 'multiple values: 0. "' .. perl.join('","', { use[0], use[1], use[2], use[3], use[4] }) .. '\n' ..
                '                                ", 1. "' .. perl.join('","', { ind[0], ind[1], ind[2] }) .. '"',
        Count = -1,
        PrintConv = function(_self, val)
            local a = perl.split(' ', perlStr(val))
            local rtn = {}
            for i = 2, #a do
                local n = tonumber(a[i])
                rtn[#rtn + 1] = (((i - 1) & 1) ~= 0 and use[n] or ind[n]) or ('Unknown(' .. a[i] .. ')')
            end
            return perl.join('; ', rtn)
        end,
        PrintConvInv = function(_self, val)
            local a = perl.split('; ?', perlStr(val))
            local rtn = {}
            for i = 1, #a do
                local v, multi = require('lexiftool.Writer').ReverseLookup(a[i],
                    ((i - 1) & 1) ~= 0 and ind or use)
                if v == nil then
                    ExifTool.evalWarning = [[Can't convert "]] .. a[i] .. '" (' ..
                        (multi and 'multiple' or 'no') .. ' matches)'
                    return nil
                end
                rtn[#rtn + 1] = v
            end
            return perl.join(' ', { perlInt(#rtn / 2), table.unpack(rtn) })
        end,
    },
    [0x9290] = {
        Name = 'SubSecTime',
        Groups = { [2] = 'Time' },
        Notes = 'fractional seconds for ModifyDate',
        Writable = 'string',
        ValueConv = function(_self, val) return (perlStr(val):gsub(' +$', '')) end,
        ValueConvInv = function(_self, val)
            local m = matches(val, [[^(\d+)\s*$]])
            if m then return m end
            m = matches(val, [[\.(\d+)]])
            return m
        end,
    },
    [0x9291] = {
        Name = 'SubSecTimeOriginal',
        Groups = { [2] = 'Time' },
        Notes = 'fractional seconds for DateTimeOriginal',
        Writable = 'string',
        ValueConv = function(_self, val) return (perlStr(val):gsub(' +$', '')) end,
        ValueConvInv = function(_self, val)
            local m = matches(val, [[^(\d+)\s*$]])
            if m then return m end
            m = matches(val, [[\.(\d+)]])
            return m
        end,
    },
    [0x9292] = {
        Name = 'SubSecTimeDigitized',
        Groups = { [2] = 'Time' },
        Notes = 'fractional seconds for CreateDate',
        Writable = 'string',
        ValueConv = function(_self, val) return (perlStr(val):gsub(' +$', '')) end,
        ValueConvInv = function(_self, val)
            local m = matches(val, [[^(\d+)\s*$]])
            if m then return m end
            m = matches(val, [[\.(\d+)]])
            return m
        end,
    },
    -- The following 3 tags are found in MSOffice TIFF images
    -- References:
    -- http://social.msdn.microsoft.com/Forums/en-US/os_standocs/thread/03086d55-294a-49d5-967a-5303d34c40f8/
    -- http://blogs.msdn.com/openspecification/archive/2009/12/08/
    --   details-of-three-tiff-tag-extensions-that-microsoft-office-document-
    --   imaging-modi-software-may-write-into-the-tiff-files-it-generates.aspx
    -- http://www.microsoft.com/downloads/details.aspx?FamilyID=0dbc435d-3544-4f4b-9092-2f2643d64a39&displaylang=en#filelist
    [0x932f] = 'MSDocumentText',
    [0x9330] = {
        Name = 'MSPropertySetStorage',
        Binary = 1,
    },
    [0x9331] = {
        Name = 'MSDocumentTextPosition',
        Binary = 1, -- (just in case -- don't know what format this is)
    },
    [0x935c] = { --3/19
        Name = 'ImageSourceData', -- (writable directory!)
        Writable = 'undef',
        WriteGroup = 'IFD0',
        SubDirectory = { TagTable = 'lexiftool.Photoshop.DocumentData' },
        Binary = 1,
        Protected = 1, -- (because this can be hundreds of megabytes)
        ReadFromRAF = 1, -- don't load into memory when reading
    },
    [0x9400] = {
        Name = 'AmbientTemperature',
        Notes = 'ambient temperature in degrees C, called Temperature by the EXIF spec.',
        Writable = 'rational64s',
        PrintConv = function(_self, val) return perlStr(val) .. ' C' end,
        PrintConvInv = function(_self, val) return perl.subst(perlStr(val), ' ?C', '') end,
    },
    [0x9401] = {
        Name = 'Humidity',
        Notes = 'ambient relative humidity in percent',
        Writable = 'rational64u',
    },
    [0x9402] = {
        Name = 'Pressure',
        Notes = 'air pressure in hPa or mbar',
        Writable = 'rational64u',
    },
    [0x9403] = {
        Name = 'WaterDepth',
        Notes = 'depth under water in metres, negative for above water',
        Writable = 'rational64s',
    },
    [0x9404] = {
        Name = 'Acceleration',
        Notes = 'directionless camera acceleration in units of mGal, or 10-5 m/s2',
        Writable = 'rational64u',
    },
    [0x9405] = {
        Name = 'CameraElevationAngle',
        Writable = 'rational64s',
    },
    [0x9999] = { -- (ExifIFD, Xiaomi)
        Name = 'XiaomiSettings', -- (writable directory!)
        Writable = 'string',
        Protected = 1,
        SubDirectory = { TagTable = 'lexiftool.JSON.Main' },
    },
    [0x9a00] = {
        Name = 'XiaomiModel',
        Writable = 'string',
        Protected = 1,
    },
  -- 0x9aaa - int8u[2048/2176]: ? (ExifIFD, Xiaomi POCO F1)
    [0x9c9b] = {
        Name = 'XPTitle',
        Format = 'undef',
        Writable = 'int8u',
        WriteGroup = 'IFD0',
        Notes = [[
            tags 0x9c9b-0x9c9f are used by Windows Explorer; special characters
            in these values are converted to UTF-8 by default, or Windows Latin1
            with the -L option.  XPTitle is ignored by Windows Explorer if
            ImageDescription exists
        ]],
        ValueConv = function(self, val) return self:Decode(val, 'UCS2', 'II') end,
        ValueConvInv = function(self, val) return self:Encode(val, 'UCS2', 'II') .. '\0\0' end,
    },
    [0x9c9c] = {
        Name = 'XPComment',
        Format = 'undef',
        Writable = 'int8u',
        WriteGroup = 'IFD0',
        ValueConv = function(self, val) return self:Decode(val, 'UCS2', 'II') end,
        ValueConvInv = function(self, val) return self:Encode(val, 'UCS2', 'II') .. '\0\0' end,
    },
    [0x9c9d] = {
        Name = 'XPAuthor',
        Groups = { [2] = 'Author' },
        Format = 'undef',
        Writable = 'int8u',
        WriteGroup = 'IFD0',
        Notes = 'ignored by Windows Explorer if Artist exists',
        ValueConv = function(self, val) return self:Decode(val, 'UCS2', 'II') end,
        ValueConvInv = function(self, val) return self:Encode(val, 'UCS2', 'II') .. '\0\0' end,
    },
    [0x9c9e] = {
        Name = 'XPKeywords',
        Format = 'undef',
        Writable = 'int8u',
        WriteGroup = 'IFD0',
        ValueConv = function(self, val) return self:Decode(val, 'UCS2', 'II') end,
        ValueConvInv = function(self, val) return self:Encode(val, 'UCS2', 'II') .. '\0\0' end,
    },
    [0x9c9f] = {
        Name = 'XPSubject',
        Format = 'undef',
        Writable = 'int8u',
        WriteGroup = 'IFD0',
        ValueConv = function(self, val) return self:Decode(val, 'UCS2', 'II') end,
        ValueConvInv = function(self, val) return self:Encode(val, 'UCS2', 'II') .. '\0\0' end,
    },
    [0xa000] = {
        Name = 'FlashpixVersion',
        Writable = 'undef',
        Mandatory = 1,
        RawConv = function(_self, val) val = subst(val, [[\0+$]], '') return val end, -- (some idiots add null terminators)
        PrintConvInv = function(_self, val)
            val = tr(val, '.', '', 'd')
            if perl.isMatch(val, [[^\d{4}$]]) then return val end
            return nil
        end,
    },
    [0xa001] = {
        Name = 'ColorSpace',
        Notes = [[
            the value of 0x2 is not standard EXIF.  Instead, an Adobe RGB image is
            indicated by "Uncalibrated" with an InteropIndex of "R03".  The values
            0xfffd and 0xfffe are also non-standard, and are used by some Sony cameras
        ]],
        Writable = 'int16u',
        Mandatory = 1,
        PrintHex = 1,
        PrintConv = {
            [1] = 'sRGB',
            [2] = 'Adobe RGB',
            [0xffff] = 'Uncalibrated',
            -- Sony uses these definitions: (ref JD)
            -- 0xffff => 'Adobe RGB', (conflicts with Uncalibrated)
            [0xfffe] = 'ICC Profile',
            [0xfffd] = 'Wide Gamut RGB',
        },
    },
    [0xa002] = {
        Name = 'ExifImageWidth',
        Notes = 'called PixelXDimension by the EXIF spec.',
        Writable = 'int16u',
        Mandatory = 1,
    },
    [0xa003] = {
        Name = 'ExifImageHeight',
        Notes = 'called PixelYDimension by the EXIF spec.',
        Writable = 'int16u',
        Mandatory = 1,
    },
    [0xa004] = {
        Name = 'RelatedSoundFile',
        Writable = 'string',
    },
    [0xa005] = {
        Name = 'InteropOffset',
        Groups = { [1] = 'InteropIFD' },
        Flags = 'SubIFD',
        Description = 'Interoperability Offset',
        SubDirectory = {
            DirName = 'InteropIFD',
            Start = function(_self, val, _valuePtr) return val end,
            MaxSubdirs = 1,
        },
    },
    -- the following 4 tags found in SubIFD1 of some Samsung SRW images
    [0xa010] = {
        Name = 'SamsungRawPointersOffset',
        IsOffset = 1,
        OffsetPair = 0xa011, -- point to associated byte count
    },
    [0xa011] = {
        Name = 'SamsungRawPointersLength',
        OffsetPair = 0xa010, -- point to associated offset
    },
    [0xa101] = {
        Name = 'SamsungRawByteOrder',
        Format = 'undef',
        -- this is written incorrectly as string[1], but is "\0\0MM" or "II\0\0"
        FixedSize = 4,
        Count = 1,
    },
    [0xa102] = {
        Name = 'SamsungRawUnknown',
        Unknown = 1,
    },
    [0xa20b] = {
        Name = 'FlashEnergy',
        Groups = { [2] = 'Camera' },
        Writable = 'rational64u',
    },
    [0xa20c] = {
        Name = 'SpatialFrequencyResponse',
        PrintConv = function(_self, val) return PrintSFR(val) end,
    },
    [0xa20d] = 'Noise',
    [0xa20e] = {
        Name = 'FocalPlaneXResolution',
        Groups = { [2] = 'Camera' },
        Writable = 'rational64u',
    },
    [0xa20f] = {
        Name = 'FocalPlaneYResolution',
        Groups = { [2] = 'Camera' },
        Writable = 'rational64u',
    },
    [0xa210] = {
        Name = 'FocalPlaneResolutionUnit',
        Groups = { [2] = 'Camera' },
        Notes = 'values 1, 4 and 5 are not standard EXIF',
        Writable = 'int16u',
        PrintConv = {
            [1] = 'None', -- (not standard EXIF)
            [2] = 'inches',
            [3] = 'cm',
            [4] = 'mm',   -- (not standard EXIF)
            [5] = 'um',   -- (not standard EXIF)
        },
    },
    [0xa211] = 'ImageNumber',
    [0xa212] = 'SecurityClassification',
    [0xa213] = 'ImageHistory',
    [0xa214] = {
        Name = 'SubjectLocation',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        Count = 2,
    },
    [0xa215] = { Name = 'ExposureIndex', Writable = 'rational64u' },
    [0xa216] = { Name = 'TIFF-EPStandardID', PrintConv = '$val =~ tr/ /./; $val' },
    [0xa217] = {
        Name = 'SensingMethod',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        PrintConv = {
            [1] = 'Not defined',
            [2] = 'One-chip color area',
            [3] = 'Two-chip color area',
            [4] = 'Three-chip color area',
            [5] = 'Color sequential area',
            [7] = 'Trilinear',
            [8] = 'Color sequential linear',
        },
    },
    [0xa300] = {
        Name = 'FileSource',
        Writable = 'undef',
        ValueConvInv = function(_self, val) if tonumber(val) and tonumber(val) < 256 then return string.char(tonumber(val)) end return val end,
        PrintConv = {
            [1] = 'Film Scanner',
            [2] = 'Reflection Print Scanner',
            [3] = 'Digital Camera',
            ['\3\0\0\0'] = 'Sigma Digital Camera',
        },
    },
    [0xa301] = {
        Name = 'SceneType',
        Writable = 'undef',
        ValueConvInv = function(_self, val) return string.char(math.tointeger(perl.int(val)) & 0xff) end,
        PrintConv = {
            [1] = 'Directly photographed',
        },
    },
    [0xa302] = {
        Name = 'CFAPattern',
        Writable = 'undef',
        RawConv = DecodeCFAPattern,
        RawConvInv = function(_self, val)
            local a = split(' ', val)
            if #a <= 2 then return val end -- also accept binary data for backward compatibility
            return perl.pack(ExifTool.GetByteOrder() == 'II' and 'v2C*' or 'n2C*', table.unpack(a))
        end,
        PrintConv = function(_self, val) return PrintCFAPattern(val) end,
        PrintConvInv = function(_self, val) return require('lexiftool.WriteExif').GetCFAPattern(val) end,
    },
    [0xa401] = {
        Name = 'CustomRendered',
        Writable = 'int16u',
        Notes = [[
            only 0 and 1 are standard EXIF, but other values are used by Apple iOS
            devices
        ]],
        PrintConv = {
            [0] = 'Normal',
            [1] = 'Custom',
            [2] = 'HDR (no original saved)',
            [3] = 'HDR (original saved)',
            [4] = 'Original (for HDR)',
            [6] = 'Panorama',
            [7] = 'Portrait HDR',
            [8] = 'Portrait',
        },
    },
    [0xa402] = {
        Name = 'ExposureMode',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Manual',
            [2] = 'Auto bracket',
        },
    },
    [0xa403] = {
        Name = 'WhiteBalance',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        Priority = 0,
        PrintConv = {
            [0] = 'Auto',
            [1] = 'Manual',
        },
    },
    [0xa404] = {
        Name = 'DigitalZoomRatio',
        Groups = { [2] = 'Camera' },
        Writable = 'rational64u',
    },
    [0xa405] = {
        Name = 'FocalLengthIn35mmFormat',
        Notes = 'called FocalLengthIn35mmFilm by the EXIF spec.',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        PrintConv = function(_self, val) return perlStr(val) .. ' mm' end,
        PrintConvInv = function(_self, val) return (subst(val, [[\s*mm$]], '')) end,
    },
    [0xa406] = {
        Name = 'SceneCaptureType',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        Notes = 'the value of 4 is non-standard, and used by some Samsung models',
        PrintConv = {
            [0] = 'Standard',
            [1] = 'Landscape',
            [2] = 'Portrait',
            [3] = 'Night',
            [4] = 'Other',
        },
    },
    [0xa407] = {
        Name = 'GainControl',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        PrintConv = {
            [0] = 'None',
            [1] = 'Low gain up',
            [2] = 'High gain up',
            [3] = 'Low gain down',
            [4] = 'High gain down',
        },
    },
    [0xa408] = {
        Name = 'Contrast',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Normal',
            [1] = 'Low',
            [2] = 'High',
        },
        PrintConvInv = ConvertParameter,
    },
    [0xa409] = {
        Name = 'Saturation',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Normal',
            [1] = 'Low',
            [2] = 'High',
        },
        PrintConvInv = ConvertParameter,
    },
    [0xa40a] = {
        Name = 'Sharpness',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Normal',
            [1] = 'Soft',
            [2] = 'Hard',
        },
        PrintConvInv = ConvertParameter,
    },
    [0xa40b] = {
        Name = 'DeviceSettingDescription',
        Groups = { [2] = 'Camera' },
        Binary = 1,
    },
    [0xa40c] = {
        Name = 'SubjectDistanceRange',
        Groups = { [2] = 'Camera' },
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Macro',
            [2] = 'Close',
            [3] = 'Distant',
        },
    },
    -- 0xa40d - int16u: 0 (GE E1486 TW)
    [0xa40d] = { --Exif3.1
        Name = 'DevelopmentType',
        Writable = 'int16u',
        ValueConv = function(_self, val) return (val >> 8) .. ' ' .. (val & 0xff) end,
        ValueConvInv = function(_self, val)
            local a = perl.split(' ', perlStr(val))
            return ((tonumber(a[1]) & 0xff) << 8) + (tonumber(a[2]) & 0xff)
        end,
        PrintConv = { {
            [1] = 'Accurate Reproduction',
            [2] = 'Small Differences',
            [4] = 'Extreme Differences',
        }, {
            [1] = 'Factory Default Settings',
            [2] = 'Not Default Settings',
            [4] = 'Unknown Settings',
        } },
    },
    -- 0xa40e - int16u: 1 (GE E1486 TW)
    [0xa40e] = { --Exif3.1
        Name = 'DevelopmentTypeDescription',
        Writable = 'string',
        ValueConv = function(self, val) return self:Decode(val, 'UTF8') end,
        ValueConvInv = function(self, val) return self:Encode(val, 'UTF8') end,
    },
    [0xa40f] = { --Exif3.1
        Name = 'DistortionCorrection',
        Writable = 'int16u',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0xa410] = { --Exif3.1
        Name = 'ChromaticAberrationCorrection',
        Writable = 'int16u',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0xa411] = { --Exif3.1
        Name = 'ShadingCorrection',
        Writable = 'int16u',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0xa412] = { --Exif3.1
        Name = 'NoiseReduction',
        Writable = 'int16u',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0xa420] = {
        Name = 'ImageUniqueID',
        Writable = 'string',
    },
    [0xa430] = { --#24
        Name = 'OwnerName',
        Notes = 'called CameraOwnerName by the EXIF spec.',
        Writable = 'string',
    },
    [0xa431] = { --#24
        Name = 'SerialNumber',
        Notes = 'called BodySerialNumber by the EXIF spec.',
        Writable = 'string',
    },
    [0xa432] = { --#24
        Name = 'LensInfo',
        Notes = [[
            4 rational values giving focal and aperture ranges, called LensSpecification
            by the EXIF spec.
        ]],
        Writable = 'rational64u',
        Count = 4,
        -- convert to the form "12-20mm f/3.8-4.5" or "50mm f/1.4"
        PrintConv = function(_self, val) return PrintLensInfo(val) end,
        PrintConvInv = function(_self, val) return require('lexiftool.WriteExif').ConvertLensInfo(val) end,
    },
    [0xa433] = { Name = 'LensMake', Writable = 'string' }, --#24
    [0xa434] = { Name = 'LensModel', Writable = 'string' }, --#24
    [0xa435] = { Name = 'LensSerialNumber', Writable = 'string' }, --#24
    [0xa436] = { Name = 'ImageTitle',       Writable = 'string' }, --33
    [0xa437] = { Name = 'Photographer',     Writable = 'string' }, --33
    [0xa438] = { Name = 'ImageEditor',      Writable = 'string' }, --33
    [0xa439] = { Name = 'CameraFirmware',          Writable = 'string' }, --33
    [0xa43a] = { Name = 'RAWDevelopingSoftware',   Writable = 'string' }, --33
    [0xa43b] = { Name = 'ImageEditingSoftware',    Writable = 'string' }, --33
    [0xa43c] = { Name = 'MetadataEditingSoftware', Writable = 'string' }, --33
    [0xa460] = { --Exif2.32
        Name = 'CompositeImage',
        Writable = 'int16u',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Not a Composite Image',
            [2] = 'General Composite Image',
            [3] = 'Composite Image Captured While Shooting',
        },
    },
    [0xa461] = { --Exif2.32
        Name = 'CompositeImageCount',
        Notes = [[
            2 values: 1. Number of source images, 2. Number of images used.  Called
            SourceImageNumberOfCompositeImage by the EXIF spec.
        ]],
        Writable = 'int16u',
        Count = 2,
    },
    [0xa462] = { --Exif2.32
        Name = 'CompositeImageExposureTimes',
        Notes = [[
            11 or more values: 1. Total exposure time period, 2. Total exposure of all
            source images, 3. Total exposure of all used images, 4. Max exposure time of
            source images, 5. Max exposure time of used images, 6. Min exposure time of
            source images, 7. Min exposure of used images, 8. Number of sequences, 9.
            Number of source images in sequence. 10-N. Exposure times of each source
            image. Called SourceExposureTimesOfCompositeImage by the EXIF spec.
        ]],
        Writable = 'undef',
        -- (upstream reads a packed block: rational64u values, except the
        --  16-bit counts at byte offsets 56 and 58)
        RawConv = function(_self, val)
            local v = {}
            local i = 0
            while true do
                if i == 56 or i == 58 then
                    if i + 2 > #val then break end
                    v[#v + 1] = ExifTool.Get16u(val, i)
                    i = i + 2
                else
                    if i + 8 > #val then break end
                    v[#v + 1] = ExifTool.GetRational64u(val, i)
                    i = i + 8
                end
            end
            return perl.join(' ', v)
        end,
        RawConvInv = function(_self, val)
            local v = perl.split(' ', perlStr(val))
            for i = 1, #v do
                -- (upstream packs each value back with Set16u/SetRational64u;
                --  the port has no pack-style SetRational64u, so the write side
                --  of this tag is deferred -- see the module Port notes)
                v[i] = perlStr(v[i])
            end
            return perl.join('', v)
        end,
        PrintConv = function(_self, val)
            local v = perl.split(' ', val)
            for i = 1, #v do
                if i ~= 8 and i ~= 9 then v[i] = PrintExposureTime(v[i]) end
            end
            return perl.join(' ', v)
        end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0xa480] = { Name = 'GDALMetadata',     Writable = 'string', WriteGroup = 'IFD0' }, --3
    [0xa481] = { Name = 'GDALNoData',       Writable = 'string', WriteGroup = 'IFD0' }, --3
    [0xa500] = { Name = 'Gamma', Writable = 'rational64u' },
  -- 0xa661 - string: ? (ExifIFD, Xiaomi)
    [0xafc0] = 'ExpandSoftware', --JD (Opanda)
    [0xafc1] = 'ExpandLens', --JD (Opanda)
    [0xafc2] = 'ExpandFilm', --JD (Opanda)
    [0xafc3] = 'ExpandFilterLens', --JD (Opanda)
    [0xafc4] = 'ExpandScanner', --JD (Opanda)
    [0xafc5] = 'ExpandFlashLamp', --JD (Opanda)
    [0xb4c3] = { Name = 'HasselbladRawImage', Format = 'undef', Binary = 1 }, --IB
--
-- Windows Media Photo / HD Photo (WDP/HDP) tags
--
    [0xbc01] = { --13
        Name = 'PixelFormat',
        PrintHex = 1,
        Format = 'undef',
        Notes = [[
            tags 0xbc** are used in Windows HD Photo (HDP and WDP) images. The actual
            PixelFormat values are 16-byte GUID's but the leading 15 bytes,
            '6fddc324-4e03-4bfe-b1853-d77768dc9', have been removed below to avoid
            unnecessary clutter
        ]],
        ValueConv = function(_self, val)
            local ASF = require('lexiftool.ASF')
            val = ASF.GetGUID(val)
            -- GUID's are too long, so remove redundant information
            local short = perl.subst(val, '(?i)^6fddc324-4e03-4bfe-b185-3d77768dc9', '')
            if short ~= val then val = tonumber(short, 16) end
            return val
        end,
        PrintConv = {
            [0x0d] = '24-bit RGB',
            [0x0c] = '24-bit BGR',
            [0x0e] = '32-bit BGR',
            [0x15] = '48-bit RGB',
            [0x12] = '48-bit RGB Fixed Point',
            [0x3b] = '48-bit RGB Half',
            [0x18] = '96-bit RGB Fixed Point',
            [0x1b] = '128-bit RGB Float',
            [0x0f] = '32-bit BGRA',
            [0x16] = '64-bit RGBA',
            [0x1d] = '64-bit RGBA Fixed Point',
            [0x3a] = '64-bit RGBA Half',
            [0x1e] = '128-bit RGBA Fixed Point',
            [0x19] = '128-bit RGBA Float',
            [0x10] = '32-bit PBGRA',
            [0x17] = '64-bit PRGBA',
            [0x1a] = '128-bit PRGBA Float',
            [0x1c] = '32-bit CMYK',
            [0x2c] = '40-bit CMYK Alpha',
            [0x1f] = '64-bit CMYK',
            [0x2d] = '80-bit CMYK Alpha',
            [0x20] = '24-bit 3 Channels',
            [0x21] = '32-bit 4 Channels',
            [0x22] = '40-bit 5 Channels',
            [0x23] = '48-bit 6 Channels',
            [0x24] = '56-bit 7 Channels',
            [0x25] = '64-bit 8 Channels',
            [0x2e] = '32-bit 3 Channels Alpha',
            [0x2f] = '40-bit 4 Channels Alpha',
            [0x30] = '48-bit 5 Channels Alpha',
            [0x31] = '56-bit 6 Channels Alpha',
            [0x32] = '64-bit 7 Channels Alpha',
            [0x33] = '72-bit 8 Channels Alpha',
            [0x26] = '48-bit 3 Channels',
            [0x27] = '64-bit 4 Channels',
            [0x28] = '80-bit 5 Channels',
            [0x29] = '96-bit 6 Channels',
            [0x2a] = '112-bit 7 Channels',
            [0x2b] = '128-bit 8 Channels',
            [0x34] = '64-bit 3 Channels Alpha',
            [0x35] = '80-bit 4 Channels Alpha',
            [0x36] = '96-bit 5 Channels Alpha',
            [0x37] = '112-bit 6 Channels Alpha',
            [0x38] = '128-bit 7 Channels Alpha',
            [0x39] = '144-bit 8 Channels Alpha',
            [0x08] = '8-bit Gray',
            [0x0b] = '16-bit Gray',
            -- luacheck: push ignore 314
            [0x13] = '16-bit Gray Fixed Point',
            [0x3e] = '16-bit Gray Half',
            [0x3f] = '32-bit Gray Fixed Point',
            [0x11] = '32-bit Gray Float',
            [0x05] = 'Black & White',
            [0x09] = '16-bit BGR555',
            [0x0a] = '16-bit BGR565',
            -- (upstream Exif.pm has 0x13 twice, at :3197 and :3204 -- Perl and
            --  a Lua table constructor both keep the last assignment)
            [0x13] = '32-bit BGR101010',
            -- luacheck: pop
            [0x3d] = '32-bit RGBE',
        },
    },
    [0xbc02] = { --13
        Name = 'Transformation',
        PrintConv = {
            [0] = 'Horizontal (normal)',
            [1] = 'Mirror vertical',
            [2] = 'Mirror horizontal',
            [3] = 'Rotate 180',
            [4] = 'Rotate 90 CW',
            [5] = 'Mirror horizontal and rotate 90 CW',
            [6] = 'Mirror horizontal and rotate 270 CW',
            [7] = 'Rotate 270 CW',
        },
    },
    [0xbc03] = { --13
        Name = 'Uncompressed',
        PrintConv = { [0] = 'No', [1] = 'Yes' },
    },
    [0xbc04] = { --13
        Name = 'ImageType',
        PrintConv = { BITMASK = {
            [0] = 'Preview',
            [1] = 'Page',
        } },
    },
    [0xbc80] = 'ImageWidth', --13
    [0xbc81] = 'ImageHeight', --13
    [0xbc82] = 'WidthResolution', --13
    [0xbc83] = 'HeightResolution', --13
    [0xbcc0] = { --13
        Name = 'ImageOffset',
        IsOffset = 1,
        IsImageData = 1,
        OffsetPair = 0xbcc1, -- point to associated byte count
    },
    [0xbcc1] = { --13
        Name = 'ImageByteCount',
        OffsetPair = 0xbcc0, -- point to associated offset
    },
    [0xbcc2] = { --13
        Name = 'AlphaOffset',
        IsOffset = 1,
        IsImageData = 1,
        OffsetPair = 0xbcc3, -- point to associated byte count
    },
    [0xbcc3] = { --13
        Name = 'AlphaByteCount',
        OffsetPair = 0xbcc2, -- point to associated offset
    },
    [0xbcc4] = { --13
        Name = 'ImageDataDiscard',
        PrintConv = {
            [0] = 'Full Resolution',
            [1] = 'Flexbits Discarded',
            [2] = 'HighPass Frequency Data Discarded',
            [3] = 'Highpass and LowPass Frequency Data Discarded',
        },
    },
    [0xbcc5] = { --13
        Name = 'AlphaDataDiscard',
        PrintConv = {
            [0] = 'Full Resolution',
            [1] = 'Flexbits Discarded',
            [2] = 'HighPass Frequency Data Discarded',
            [3] = 'Highpass and LowPass Frequency Data Discarded',
        },
    },
--
    [0xc427] = 'OceScanjobDesc', --3
    [0xc428] = 'OceApplicationSelector', --3
    [0xc429] = 'OceIDNumber', --3
    [0xc42a] = 'OceImageLogic', --3
    [0xc44f] = { Name = 'Annotations', Binary = 1 }, --7/19
    [0xc4a5] = {
        Name = 'PrintIM', -- (writable directory!)
        -- must set Writable here so this tag will be saved with MakerNotes option
        Writable = 'undef',
        WriteGroup = 'IFD0',
        Binary = 1,
        -- (don't make Binary/Protected because we can't copy individual PrintIM tags anyway)
        Description = 'Print Image Matching',
        SubDirectory = {
            TagTable = 'lexiftool.PrintIM.Main',
        },
        PrintConvInv = function(_self, val) if perl.isMatch(val, '^PrintIM') then return val end return nil end,
    },
    [0xc519] = { -- (Hasselblad X2D)
        Name = 'HasselbladXML',
        Format = 'undef',
        TruncateOK = 1, -- (incorrect size written by X2D)
        SubDirectory = {
            DirName = 'XML',
            TagTable = 'lexiftool.PLIST.Main',
            Start = function(_self, _val, start) return start + 4 end,
        },
    },
    [0xc51b] = { -- (Hasselblad H3D)
        Name = 'HasselbladExif',
        Format = 'undef',
        SubDirectory = {
            Start = function(_self, _val, start) return start end,
            Base = function(_self, _val, start) return start end,
            TagTable = 'lexiftool.Exif.Main',
            ProcessProc = function(et, di, tt) return ExifTool.ProcessSubTIFF(et, di, tt) end,
            -- Writing this is problematic due to the braindead Hasselblad programmers.
            -- One problem is that some values run outside the HasselbladExif data so they
            -- will be lost if we do a simple copy (which is what we are currently doing
            -- by returning undef from the WriteProc), but we can't rebuild this directory
            -- by writing it properly because there is an erroneous StripByteCounts value
            -- written by the X2D 100C that renders the data unreadable
            WriteProc = function() return nil end,
        },
    },
    [0xc573] = { --PH
        Name = 'OriginalFileName',
        Notes = 'used by some obscure software', -- (possibly Swizzy Photosmacker?)
        -- (it is a 'string', but obscure, so don't make it writable)
    },
    [0xc580] = { --20
        Name = 'USPTOOriginalContentType',
        PrintConv = {
            [0] = 'Text or Drawing',
            [1] = 'Grayscale',
            [2] = 'Color',
        },
    },
    -- 0xc5d8 - found in CR2 images
    -- 0xc5d9 - found in CR2 images
    [0xc5e0] = { --forum8153 (CR2 images)
        Name = 'CR2CFAPattern',
        ValueConv = {
            [1] = '0 1 1 2',
            [2] = '2 1 1 0',
            [3] = '1 2 0 1',
            [4] = '1 0 2 1',
        },
        PrintConv = {
            ['0 1 1 2'] = '[Red,Green][Green,Blue]',
            ['2 1 1 0'] = '[Blue,Green][Green,Red]',
            ['1 2 0 1'] = '[Green,Blue][Red,Green]',
            ['1 0 2 1'] = '[Green,Red][Blue,Green]',
        },
    },
    -- DNG tags 0xc6XX, 0xc7XX and 0xcdXX (ref 2 unless otherwise stated)
    [0xc612] = {
        Name = 'DNGVersion',
        Notes = [[
            tags 0xc612-0xcd48 are defined by the DNG specification unless otherwise
            noted.  See L<https://helpx.adobe.com/photoshop/digital-negative.html> for
            the specification
        ]],
        Writable = 'int8u',
        WriteGroup = 'IFD0',
        Count = 4,
        Protected = 1, -- (confuses Apple Preview if written to a TIFF image)
        DataMember = 'DNGVersion',
        RawConv = function(self, val)
            self.DNGVersion = val
            return val
        end,
        PrintConv = function(_self, val) return (perlStr(val):gsub(' ', '.')) end,
        PrintConvInv = function(_self, val) return (tr(val, '.', ' ')) end,
    },
    [0xc613] = {
        Name = 'DNGBackwardVersion',
        Writable = 'int8u',
        WriteGroup = 'IFD0',
        Count = 4,
        Protected = 1,
        PrintConv = function(_self, val) return (perlStr(val):gsub(' ', '.')) end,
        PrintConvInv = function(_self, val) return (tr(val, '.', ' ')) end,
    },
    [0xc614] = {
        Name = 'UniqueCameraModel',
        Writable = 'string',
        WriteGroup = 'IFD0',
    },
    [0xc615] = utf8StringConv {
        Name = 'LocalizedCameraModel',
        WriteGroup = 'IFD0',
        PrintConv = function(self, val) return self:Printable(val, 0) end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0xc616] = {
        Name = 'CFAPlaneColor',
        WriteGroup = 'SubIFD', -- (only for Validate)
        PrintConv = function(_self, val)
            local cols = { 'Red', 'Green', 'Blue', 'Cyan', 'Magenta', 'Yellow', 'White' }
            local out = {}
            for v in perlStr(val):gmatch('[^ \t\n\r\f\v]+') do
                out[#out + 1] = cols[tonumber(v) + 1] or ('Unknown(' .. v .. ')')
            end
            return table.concat(out, ',')
        end,
    },
    [0xc617] = {
        Name = 'CFALayout',
        WriteGroup = 'SubIFD', -- (only for Validate)
        PrintConv = {
            [1] = 'Rectangular',
            [2] = 'Even columns offset down 1/2 row',
            [3] = 'Even columns offset up 1/2 row',
            [4] = 'Even rows offset right 1/2 column',
            [5] = 'Even rows offset left 1/2 column',
            [6] = 'Even rows offset up by 1/2 row, even columns offset left by 1/2 column',
            [7] = 'Even rows offset up by 1/2 row, even columns offset right by 1/2 column',
            [8] = 'Even rows offset down by 1/2 row, even columns offset left by 1/2 column',
            [9] = 'Even rows offset down by 1/2 row, even columns offset right by 1/2 column',
        },
    },
    [0xc618] = {
        Name = 'LinearizationTable',
        Writable = 'int16u',
        WriteGroup = 'SubIFD',
        Count = -1,
        Protected = 1,
        Binary = 1,
    },
    [0xc619] = {
        Name = 'BlackLevelRepeatDim',
        Writable = 'int16u',
        WriteGroup = 'SubIFD',
        Count = 2,
        Protected = 1,
    },
    [0xc61a] = {
        Name = 'BlackLevel',
        Writable = 'rational64u',
        WriteGroup = 'SubIFD',
        Count = -1,
        Protected = 1,
    },
    [0xc61b] = longBin {
        Name = 'BlackLevelDeltaH',
        Writable = 'rational64s',
        WriteGroup = 'SubIFD',
        Count = -1,
        Protected = 1,
    },
    [0xc61c] = longBin {
        Name = 'BlackLevelDeltaV',
        Writable = 'rational64s',
        WriteGroup = 'SubIFD',
        Count = -1,
        Protected = 1,
    },
    [0xc61d] = {
        Name = 'WhiteLevel',
        Writable = 'int32u',
        WriteGroup = 'SubIFD',
        Count = -1,
        Protected = 1,
    },
    [0xc61e] = {
        Name = 'DefaultScale',
        Writable = 'rational64u',
        WriteGroup = 'SubIFD',
        Count = 2,
        Protected = 1,
    },
    [0xc61f] = {
        Name = 'DefaultCropOrigin',
        Writable = 'int32u',
        WriteGroup = 'SubIFD',
        Count = 2,
        Protected = 1,
    },
    [0xc620] = {
        Name = 'DefaultCropSize',
        Writable = 'int32u',
        WriteGroup = 'SubIFD',
        Count = 2,
        Protected = 1,
    },
    [0xc621] = {
        Name = 'ColorMatrix1',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc622] = {
        Name = 'ColorMatrix2',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc623] = {
        Name = 'CameraCalibration1',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc624] = {
        Name = 'CameraCalibration2',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc625] = {
        Name = 'ReductionMatrix1',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc626] = {
        Name = 'ReductionMatrix2',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc627] = {
        Name = 'AnalogBalance',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc628] = {
        Name = 'AsShotNeutral',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc629] = {
        Name = 'AsShotWhiteXY',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Count = 2,
        Protected = 1,
    },
    [0xc62a] = {
        Name = 'BaselineExposure',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc62b] = {
        Name = 'BaselineNoise',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc62c] = {
        Name = 'BaselineSharpness',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc62d] = {
        Name = 'BayerGreenSplit',
        Writable = 'int32u',
        WriteGroup = 'SubIFD',
        Protected = 1,
    },
    [0xc62e] = {
        Name = 'LinearResponseLimit',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc62f] = {
        Name = 'CameraSerialNumber',
        Groups = { [2] = 'Camera' },
        Writable = 'string',
        WriteGroup = 'IFD0',
    },
    [0xc630] = {
        Name = 'DNGLensInfo',
        Groups = { [2] = 'Camera' },
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Count = 4,
        PrintConv = function(_self, val) return PrintLensInfo(val) end,
        PrintConvInv = function(_self, val) return require('lexiftool.WriteExif').ConvertLensInfo(val) end,
    },
    [0xc631] = {
        Name = 'ChromaBlurRadius',
        Writable = 'rational64u',
        WriteGroup = 'SubIFD',
        Protected = 1,
    },
    [0xc632] = {
        Name = 'AntiAliasStrength',
        Writable = 'rational64u',
        WriteGroup = 'SubIFD',
        Protected = 1,
    },
    [0xc633] = {
        Name = 'ShadowScale',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc634] = {
        {
            Condition = function(self) return isMatch(self.TIFF_TYPE, [[^(ARW|SR2)$]]) end,
            Name = 'SR2Private',
            Groups = { [1] = 'SR2' },
            Flags = 'SubIFD',
            Format = 'int32u',
            -- some utilities have problems unless this is int8u format:
            -- - Adobe Camera Raw 5.3 gives an error
            -- - Apple Preview 10.5.8 gets the wrong white balance
            FixFormat = 'int8u', -- (stupid Sony)
            WriteGroup = 'IFD0', -- (for Validate)
            SubDirectory = {
                DirName = 'SR2Private',
                TagTable = 'lexiftool.Sony.SR2Private',
                Start = function(_self, val, _start) return val end,
            },
        },
        {
            Condition = function(_self, val) return isMatch(val, [[^Adobe\0]]) end,
            Name = 'DNGAdobeData',
            Flags = { 'Binary', 'Protected' },
            Writable = 'undef', -- (writable directory!) (to make it possible to delete this mess)
            WriteGroup = 'IFD0',
            NestedHtmlDump = 1,
            SubDirectory = { TagTable = 'lexiftool.DNG.AdobeData' },
            Format = 'undef', -- but written as int8u (change to undef for speed)
        },
        {
            -- Pentax/Samsung models that write AOC maker notes in JPG images:
            -- K-5,K-7,K-m,K-x,K-r,K10D,K20D,K100D,K110D,K200D,K2000,GX10,GX20
            -- (Note: the following expression also appears in WriteExif.pl)
            Condition = function(self, val)
                return matches(val, [[^(PENTAX |SAMSUNG)\0]]) ~= nil and
                    matches(self.Model, [[\b(K(-[57mrx]|(10|20|100|110|200)D|2000)|GX(10|20))\b]]) ~= nil
            end,
            Name = 'MakerNotePentax',
            MakerNotes = 1,    -- (causes "MakerNotes header" to be identified in HtmlDump output)
            Binary = 1,
            WriteGroup = 'IFD0', -- (for Validate)
            -- Note: Don't make this block-writable for a few reasons:
            -- 1) It would be dangerous (possibly confusing Pentax software)
            -- 2) It is a different format from the JPEG version of MakerNotePentax
            -- 3) It is converted to JPEG format by RebuildMakerNotes() when copying
            SubDirectory = {
                TagTable = 'lexiftool.Pentax.Main',
                Start = function(_self, _val, valuePtr) return valuePtr + 10 end,
                Base = function(_self, _val, start) return start - 10 end,
                ByteOrder = 'Unknown', -- easier to do this than read byteorder word
            },
            Format = 'undef', -- but written as int8u (change to undef for speed)
        },
        {
            -- must duplicate the above tag with a different name for more recent
            -- Pentax models which use the "PENTAX" instead of the "AOC" maker notes
            -- in JPG images (needed when copying maker notes from DNG to JPG)
            Condition = function(_self, val) return matches(val, [[^(PENTAX |SAMSUNG)\0]]) ~= nil end,
            Name = 'MakerNotePentax5',
            MakerNotes = 1,
            Binary = 1,
            WriteGroup = 'IFD0', -- (for Validate)
            SubDirectory = {
                TagTable = 'lexiftool.Pentax.Main',
                Start = function(_self, _val, valuePtr) return valuePtr + 10 end,
                Base = function(_self, _val, start) return start - 10 end,
                ByteOrder = 'Unknown',
            },
            Format = 'undef',
        },
        {
            -- Ricoh models such as the GR III
            Condition = function(_self, val) return matches(val, [[^RICOH\0(II|MM)]]) ~= nil end,
            Name = 'MakerNoteRicohPentax',
            MakerNotes = 1,
            Binary = 1,
            WriteGroup = 'IFD0', -- (for Validate)
            SubDirectory = {
                TagTable = 'lexiftool.Pentax.Main',
                Start = function(_self, _val, valuePtr) return valuePtr + 8 end,
                Base = function(_self, _val, start) return start - 8 end,
                ByteOrder = 'Unknown',
            },
            Format = 'undef',
        },
        -- the DJI FC2103 writes some interesting stuff here (with sections labelled
        -- awb_dbg_info, ae_dbg_info, ae_histogram_info, af_dbg_info, hiso, xidiri) - PH
        {
            Name = 'MakerNoteDJIInfo',
            Condition = function(_self, val) return matches(perlStr(val), [[^\[ae_dbg_info:]]) ~= nil end,
            MakerNotes = 1,
            Binary = 1,
            NotIFD = 1,
            WriteGroup = 'IFD0', -- (for Validate)
            SubDirectory = { TagTable = 'lexiftool.DJI.Info' },
            Format = 'undef',
        },
        {
            Name = 'DNGPrivateData',
            Flags = { 'Binary', 'Protected' },
            Format = 'undef',
            Writable = 'int8u',
            WriteGroup = 'IFD0',
        },
    },
    [0xc635] = {
        Name = 'MakerNoteSafety',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        PrintConv = {
            [0] = 'Unsafe',
            [1] = 'Safe',
        },
    },
    [0xc640] = { --15
        Name = 'RawImageSegmentation',
        -- (int16u[3], not writable)
        Notes = [[
            used in segmented Canon CR2 images.  3 numbers: 1. Number of segments minus
            one; 2. Pixel width of segments except last; 3. Pixel width of last segment
        ]],
    },
    [0xc65a] = {
        Name = 'CalibrationIlluminant1',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Protected = 1,
        SeparateTable = 'LightSource',
        PrintConv = lightSource,
    },
    [0xc65b] = {
        Name = 'CalibrationIlluminant2',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Protected = 1,
        SeparateTable = 'LightSource',
        PrintConv = lightSource,
    },
    [0xc65c] = {
        Name = 'BestQualityScale',
        Writable = 'rational64u',
        WriteGroup = 'SubIFD',
        Protected = 1,
    },
    [0xc65d] = {
        Name = 'RawDataUniqueID',
        Format = 'undef',
        Writable = 'int8u',
        WriteGroup = 'IFD0',
        Count = 16,
        Protected = 1,
        ValueConv = function(_self, val)
            local out = {}
            for i = 1, #val do out[#out + 1] = string.format('%02X', val:byte(i)) end
            return table.concat(out)
        end,
        ValueConvInv = function(_self, val) return perl.pack('H*', val) end,
    },
    [0xc660] = { --3
        Name = 'AliasLayerMetadata',
        Notes = 'used by Alias Sketchbook Pro',
    },
    [0xc68b] = utf8StringConv {
        Name = 'OriginalRawFileName',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc68c] = {
        Name = 'OriginalRawFileData', -- (writable directory!)
        Writable = 'undef', -- must be defined here so tag will be extracted if specified
        WriteGroup = 'IFD0',
        Flags = { 'Binary', 'Protected' },
        SubDirectory = {
            TagTable = 'lexiftool.DNG.OriginalRaw',
        },
    },
    [0xc68d] = {
        Name = 'ActiveArea',
        Writable = 'int32u',
        WriteGroup = 'SubIFD',
        Count = 4,
        Protected = 1,
    },
    [0xc68e] = {
        Name = 'MaskedAreas',
        Writable = 'int32u',
        WriteGroup = 'SubIFD',
        Count = -1,
        Protected = 1,
    },
    [0xc68f] = {
        Name = 'AsShotICCProfile', -- (writable directory)
        Binary = 1,
        Writable = 'undef', -- must be defined here so tag will be extracted if specified
        WriteGroup = 'IFD0',
        Protected = 1,
        WriteCheck = function(_self, _tagInfo, val)
            return require('lexiftool.ICC_Profile').ValidateICC(val)
        end,
        SubDirectory = {
            DirName = 'AsShotICCProfile',
            TagTable = 'lexiftool.ICC_Profile.Main',
        },
    },
    [0xc690] = {
        Name = 'AsShotPreProfileMatrix',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc691] = {
        Name = 'CurrentICCProfile', -- (writable directory)
        Binary = 1,
        Writable = 'undef', -- must be defined here so tag will be extracted if specified
        SubDirectory = {
            DirName = 'CurrentICCProfile',
            TagTable = 'lexiftool.ICC_Profile.Main',
        },
        WriteGroup = 'IFD0',
        Protected = 1,
        WriteCheck = function(_self, _tagInfo, val)
            return require('lexiftool.ICC_Profile').ValidateICC(val)
        end,
    },
    [0xc692] = {
        Name = 'CurrentPreProfileMatrix',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc6bf] = {
        Name = 'ColorimetricReference',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Protected = 1,
        PrintConv = {
            [0] = 'Scene-referred',
            [1] = 'Output-referred (ICC Profile Dynamic Range)',
            [2] = 'Output-referred (High Dyanmic Range)', -- DNG 1.7
        },
    },
    [0xc6c5] = { Name = 'SRawType', Description = 'SRaw Type', WriteGroup = 'IFD0' }, --exifprobe (CR2 proprietary)
    [0xc6d2] = { --JD (Panasonic DMC-TZ5)
        -- this text is UTF-8 encoded (hooray!) - PH (TZ5)
        Name = 'PanasonicTitle',
        Format = 'string', -- written incorrectly as 'undef'
        Notes = 'proprietary Panasonic tag used for baby/pet name, etc',
        Writable = 'undef',
        WriteGroup = 'IFD0',
        -- panasonic always records this tag (64 zero bytes),
        -- so ignore it unless it contains valid information
        RawConv = function(_self, val) if #perlStr(val) == 0 then return nil end return val end,
        ValueConv = function(self, val) return self:Decode(val, 'UTF8') end,
        ValueConvInv = function(self, val) return self:Encode(val, 'UTF8') end,
    },
    [0xc6d3] = { --PH (Panasonic DMC-FS7)
        Name = 'PanasonicTitle2',
        Format = 'string', -- written incorrectly as 'undef'
        Notes = 'proprietary Panasonic tag used for baby/pet name with age',
        Writable = 'undef',
        WriteGroup = 'IFD0',
        -- panasonic always records this tag (128 zero bytes),
        -- so ignore it unless it contains valid information
        RawConv = function(_self, val) if #perlStr(val) == 0 then return nil end return val end,
        ValueConv = function(self, val) return self:Decode(val, 'UTF8') end,
        ValueConvInv = function(self, val) return self:Encode(val, 'UTF8') end,
    },
    -- 0xc6dc - int32u[4]: found in CR2 images (PH, 7DmkIII)
    -- 0xc6dd - int16u[256]: found in CR2 images (PH, 5DmkIV)
    [0xc6f3] = utf8StringConv {
        Name = 'CameraCalibrationSig',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc6f4] = utf8StringConv {
        Name = 'ProfileCalibrationSig',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc6f5] = {
        Name = 'ProfileIFD', -- (ExtraCameraProfiles)
        Groups = { [1] = 'ProfileIFD' },
        Flags = 'SubIFD',
        WriteGroup = 'IFD0', -- (only for Validate)
        SubDirectory = {
            ProcessProc = function(et, di, tt)
                return require('lexiftool.WriteExif').ProcessTiffIFD(et, di, tt)
            end,
            WriteProc = function(et, di, tt)
                return require('lexiftool.WriteExif').ProcessTiffIFD(et, di, tt)
            end,
            DirName = 'ProfileIFD',
            Start = function(_self, val, _start) return val end,
            Base = function(_self, _val, start) return start end, -- offsets relative to start of TIFF-like header
            MaxSubdirs = 10,
            Magic = 0x4352, -- magic number for TIFF-like header
        },
    },
    [0xc6f6] = utf8StringConv {
        Name = 'AsShotProfileName',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc6f7] = {
        Name = 'NoiseReductionApplied',
        Writable = 'rational64u',
        WriteGroup = 'SubIFD',
        Protected = 1,
    },
    [0xc6f8] = utf8StringConv {
        Name = 'ProfileName',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc6f9] = {
        Name = 'ProfileHueSatMapDims',
        Writable = 'int32u',
        WriteGroup = 'IFD0',
        Count = 3,
        Protected = 1,
    },
    [0xc6fa] = longBin {
        Name = 'ProfileHueSatMapData1',
        Writable = 'float',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc6fb] = longBin {
        Name = 'ProfileHueSatMapData2',
        Writable = 'float',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc6fc] = longBin {
        Name = 'ProfileToneCurve',
        Writable = 'float',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc6fd] = {
        Name = 'ProfileEmbedPolicy',
        Writable = 'int32u',
        WriteGroup = 'IFD0',
        Protected = 1,
        PrintConv = {
            [0] = 'Allow Copying',
            [1] = 'Embed if Used',
            [2] = 'Never Embed',
            [3] = 'No Restrictions',
        },
    },
    [0xc6fe] = utf8StringConv {
        Name = 'ProfileCopyright',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc714] = {
        Name = 'ForwardMatrix1',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc715] = {
        Name = 'ForwardMatrix2',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc716] = utf8StringConv {
        Name = 'PreviewApplicationName',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc717] = utf8StringConv {
        Name = 'PreviewApplicationVersion',
        Writable = 'string',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc718] = utf8StringConv {
        Name = 'PreviewSettingsName',
        Writable = 'string',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc719] = {
        Name = 'PreviewSettingsDigest',
        Format = 'undef',
        Writable = 'int8u',
        WriteGroup = 'IFD0',
        Protected = 1,
        ValueConv = function(_self, val) return perl.unpack('H*', val) end,
        ValueConvInv = function(_self, val) return perl.pack('H*', val) end,
    },
    [0xc71a] = {
        Name = 'PreviewColorSpace',
        Writable = 'int32u',
        WriteGroup = 'IFD0',
        Protected = 1,
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Gray Gamma 2.2',
            [2] = 'sRGB',
            [3] = 'Adobe RGB',
            [4] = 'ProPhoto RGB',
        },
    },
    [0xc71b] = {
        Name = 'PreviewDateTime',
        Groups = { [2] = 'Time' },
        Writable = 'string',
        Shift = 'Time',
        WriteGroup = 'IFD0',
        Protected = 1,
        ValueConv = function(_self, val)
            return require('lexiftool.XMP').ConvertXMPDate(val)
        end,
        ValueConvInv = function(_self, val)
            return require('lexiftool.XMP').FormatXMPDate(val)
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return self:InverseDateTime(val, 1, 1) end,
    },
    [0xc71c] = {
        Name = 'RawImageDigest',
        Format = 'undef',
        Writable = 'int8u',
        WriteGroup = 'IFD0',
        Count = 16,
        Protected = 1,
        ValueConv = function(_self, val) return perl.unpack('H*', val) end,
        ValueConvInv = function(_self, val) return perl.pack('H*', val) end,
    },
    [0xc71d] = {
        Name = 'OriginalRawFileDigest',
        Format = 'undef',
        Writable = 'int8u',
        WriteGroup = 'IFD0',
        Count = 16,
        Protected = 1,
        ValueConv = function(_self, val) return perl.unpack('H*', val) end,
        ValueConvInv = function(_self, val) return perl.pack('H*', val) end,
    },
    [0xc71e] = 'SubTileBlockSize',
    [0xc71f] = 'RowInterleaveFactor',
    [0xc725] = {
        Name = 'ProfileLookTableDims',
        Writable = 'int32u',
        WriteGroup = 'IFD0',
        Count = 3,
        Protected = 1,
    },
    [0xc726] = longBin {
        Name = 'ProfileLookTableData',
        Writable = 'float',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xc740] = opcodeInfo { Name = 'OpcodeList1' }, -- DNG 1.3
    [0xc741] = opcodeInfo { Name = 'OpcodeList2' }, -- DNG 1.3
    [0xc74e] = opcodeInfo { Name = 'OpcodeList3' }, -- DNG 1.3
    [0xc761] = { -- DNG 1.3
        Name = 'NoiseProfile',
        Writable = 'double',
        WriteGroup = 'SubIFD',
        Count = -1,
        Protected = 1,
    },
    [0xc763] = { -- #28
        Name = 'TimeCodes',
        Writable = 'int8u',
        WriteGroup = 'IFD0',
        Count = -1, -- (8 * number of time codes, max 10)
        ValueConv = timeCodesValueConv,
        ValueConvInv = timeCodesValueConvInv,
        PrintConv = timeCodesPrintConv,
        PrintConvInv = timeCodesPrintConvInv,
    },
    [0xc764] = { --28
        Name = 'FrameRate',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        PrintConv = function(_self, val) return perlInt(val * 1000 + 0.5) / 1000 end,
        PrintConvInv = function(_self, val) return val end,
    },
    [0xc772] = { --28
        Name = 'TStop',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Count = -1, -- (1 or 2)
        PrintConv = function(_self, val)
            local a = perl.split(' ', perlStr(val))
            for i = 1, #a do a[i] = sprintf('%.2f', tonumber(a[i])) end
            return perl.join('-', a)
        end,
        PrintConvInv = function(_self, val) return (perlStr(val):gsub('%-', ' ')) end,
    },
    [0xc789] = { --28
        Name = 'ReelName',
        Writable = 'string',
        WriteGroup = 'IFD0',
    },
    [0xc791] = { -- DNG 1.4
        Name = 'OriginalDefaultFinalSize',
        Writable = 'int32u',
        WriteGroup = 'IFD0',
        Count = 2,
        Protected = 1,
    },
    [0xc792] = { -- DNG 1.4
        Name = 'OriginalBestQualitySize',
        Notes = 'called OriginalBestQualityFinalSize by the DNG spec',
        Writable = 'int32u',
        WriteGroup = 'IFD0',
        Count = 2,
        Protected = 1,
    },
    [0xc793] = { -- DNG 1.4
        Name = 'OriginalDefaultCropSize',
        Writable = 'rational64u',
        WriteGroup = 'IFD0',
        Count = 2,
        Protected = 1,
    },
    [0xc7a1] = { --28
        Name = 'CameraLabel',
        Writable = 'string',
        WriteGroup = 'IFD0',
    },
    [0xc7a3] = { -- DNG 1.4
        Name = 'ProfileHueSatMapEncoding',
        Writable = 'int32u',
        WriteGroup = 'IFD0',
        Protected = 1,
        PrintConv = {
            [0] = 'Linear',
            [1] = 'sRGB',
        },
    },
    [0xc7a4] = { -- DNG 1.4
        Name = 'ProfileLookTableEncoding',
        Writable = 'int32u',
        WriteGroup = 'IFD0',
        Protected = 1,
        PrintConv = {
            [0] = 'Linear',
            [1] = 'sRGB',
        },
    },
    [0xc7a5] = { -- DNG 1.4
        Name = 'BaselineExposureOffset',
        Writable = 'rational64s', -- (incorrectly "RATIONAL" in DNG 1.4 spec)
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xc7a6] = { -- DNG 1.4
        Name = 'DefaultBlackRender',
        Writable = 'int32u',
        WriteGroup = 'IFD0',
        Protected = 1,
        PrintConv = {
            [0] = 'Auto',
            [1] = 'None',
        },
    },
    [0xc7a7] = { -- DNG 1.4
        Name = 'NewRawImageDigest',
        Format = 'undef',
        Writable = 'int8u',
        WriteGroup = 'IFD0',
        Count = 16,
        Protected = 1,
        ValueConv = function(_self, val) return perl.unpack('H*', val) end,
        ValueConvInv = function(_self, val) return perl.pack('H*', val) end,
    },
    [0xc7a8] = { -- DNG 1.4
        Name = 'RawToPreviewGain',
        Writable = 'double',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    -- 0xc7a9 - CacheBlob (ref 31)
    [0xc7aa] = { --31 undocumented DNG tag written by LR4 (val=256, related to fast load data?)
        Name = 'CacheVersion',
        Writable = 'int32u',
        WriteGroup = 'SubIFD2',
        Format = 'int8u',
        Count = 4,
        Protected = 1,
        PrintConv = function(_self, val) return (perlStr(val):gsub(' ', '.')) end,
        PrintConvInv = function(_self, val) return (perlStr(val):gsub('%.', ' ')) end,
    },
    [0xc7b5] = { -- DNG 1.4
        Name = 'DefaultUserCrop',
        Writable = 'rational64u',
        WriteGroup = 'SubIFD',
        Count = 4,
        Protected = 1,
    },
    [0xc7d5] = { --PH (in SubIFD1 of Nikon Z6/Z7 NEF images)
        Name = 'NikonNEFInfo',
        Condition = function(_self, valPt) return perl.matches(valPt or '', '^Nikon\\0') ~= nil end,
        SubDirectory = {
            TagTable = 'lexiftool.Nikon.NEFInfo',
            Start = function(_self, _val, start) return start + 18 end,
            Base = function(_self, _val, start) return start - 8 end,
            ByteOrder = 'Unknown',
        },
    },
    -- 0xc7d6 - int8u: 1 (SubIFD1 of Nikon Z6/Z7 NEF)
    [0xc7d7] = { Name = 'ZIFMetadata',    Binary = 1 },
    [0xc7d8] = { Name = 'ZIFAnnotations', Binary = 1 },
    [0xc7e9] = { -- DNG 1.5
        Name = 'DepthFormat',
        Writable = 'int16u',
        Notes = 'tags 0xc7e9-0xc7ee added by DNG 1.5.0.0',
        Protected = 1,
        WriteGroup = 'IFD0',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Linear',
            [2] = 'Inverse',
        },
    },
    [0xc7ea] = { -- DNG 1.5
        Name = 'DepthNear',
        Writable = 'rational64u',
        Protected = 1,
        WriteGroup = 'IFD0',
    },
    [0xc7eb] = { -- DNG 1.5
        Name = 'DepthFar',
        Writable = 'rational64u',
        Protected = 1,
        WriteGroup = 'IFD0',
    },
    [0xc7ec] = { -- DNG 1.5
        Name = 'DepthUnits',
        Writable = 'int16u',
        Protected = 1,
        WriteGroup = 'IFD0',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Meters',
        },
    },
    [0xc7ed] = { -- DNG 1.5
        Name = 'DepthMeasureType',
        Writable = 'int16u',
        Protected = 1,
        WriteGroup = 'IFD0',
        PrintConv = {
            [0] = 'Unknown',
            [1] = 'Optical Axis',
            [2] = 'Optical Ray',
        },
    },
    [0xc7ee] = { -- DNG 1.5
        Name = 'EnhanceParams',
        Writable = 'string',
        Protected = 1,
        WriteGroup = 'IFD0',
    },
    [0xcd2d] = { -- DNG 1.6
        Name = 'ProfileGainTableMap',
        Writable = 'undef',
        WriteGroup = 'SubIFD', -- (according to DNG 1.7 docs, this was an error and it should have been IFD0)
        Protected = 1,
        Binary = 1,
    },
    [0xcd2e] = { -- DNG 1.6
        Name = 'SemanticName',
      -- Writable => 'string',
        WriteGroup = 'SubIFD' --? (NC) Semantic Mask IFD (only for Validate)
    },
    [0xcd30] = { -- DNG 1.6
        Name = 'SemanticInstanceID',
      -- Writable => 'string',
        WriteGroup = 'SubIFD' --? (NC) Semantic Mask IFD (only for Validate)
    },
    [0xcd31] = { -- DNG 1.6
        Name = 'CalibrationIlluminant3',
        Writable = 'int16u',
        WriteGroup = 'IFD0',
        Protected = 1,
        SeparateTable = 'LightSource',
        PrintConv = lightSource,
    },
    [0xcd32] = { -- DNG 1.6
        Name = 'CameraCalibration3',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xcd33] = { -- DNG 1.6
        Name = 'ColorMatrix3',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xcd34] = { -- DNG 1.6
        Name = 'ForwardMatrix3',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xcd35] = { -- DNG 1.6
        Name = 'IlluminantData1',
        Writable = 'undef',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xcd36] = { -- DNG 1.6
        Name = 'IlluminantData2',
        Writable = 'undef',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xcd37] = { -- DNG 1.6
        Name = 'IlluminantData3',
        Writable = 'undef',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xcd38] = { -- DNG 1.6
        Name = 'MaskSubArea',
      -- Writable => 'int32u',
        WriteGroup = 'SubIFD', --? (NC) Semantic Mask IFD (only for Validate)
        Count = 4,
    },
    [0xcd39] = longBin { -- DNG 1.6
        Name = 'ProfileHueSatMapData3',
        Writable = 'float',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xcd3a] = { -- DNG 1.6
        Name = 'ReductionMatrix3',
        Writable = 'rational64s',
        WriteGroup = 'IFD0',
        Count = -1,
        Protected = 1,
    },
    [0xcd3f] = { -- DNG 1.6
        Name = 'RGBTables',
        Writable = 'undef',
        WriteGroup = 'IFD0',
        Protected = 1,
        Binary = 1,
    },
    [0xcd40] = { -- DNG 1.7
        Name = 'ProfileGainTableMap2',
        Writable = 'undef',
        WriteGroup = 'IFD0',
        Protected = 1,
        Binary = 1,
    },
    [0xcd41] = {
        Name = 'JUMBF',
        -- (set Deletable flag so we can delete this because
        --  Jpeg2000 directories are otherwise permanent)
        Deletable = 1,
        SubDirectory = {
            TagTable = 'lexiftool.Jpeg2000.Main',
            DirName = 'JUMBF',
            ByteOrder = 'BigEndian',
        },
    },
    [0xcd43] = { -- DNG 1.7
        Name = 'ColumnInterleaveFactor',
        Writable = 'int32u',
        WriteGroup = 'SubIFD',
        Protected = 1,
    },
    [0xcd44] = { -- DNG 1.7
        Name = 'ImageSequenceInfo',
        Writable = 'undef',
        WriteGroup = 'IFD0',
        SubDirectory = {
            TagTable = 'lexiftool.DNG.ImageSeq',
            ByteOrder = 'BigEndian',
        },
    },
    [0xcd46] = { -- DNG 1.7
        Name = 'ImageStats',
        Writable = 'undef',
        WriteGroup = 'IFD0',
        Binary = 1,
        Protected = 1,
    },
    [0xcd47] = { -- DNG 1.7
        Name = 'ProfileDynamicRange',
        Writable = 'undef',
        WriteGroup = 'IFD0',
        SubDirectory = {
            TagTable = 'lexiftool.DNG.ProfileDynamicRange',
            ByteOrder = 'BigEndian', -- (not indicated in spec)
        },
    },
    [0xcd48] = { -- DNG 1.7
        Name = 'ProfileGroupName',
        Writable = 'string',
        Format = 'string',
        WriteGroup = 'IFD0',
        Protected = 1,
    },
    [0xcd49] = { -- DNG 1.7.1
        Name = 'JXLDistance',
        Writable = 'float',
        WriteGroup = 'IFD0',
    },
    [0xcd4a] = { -- DNG 1.7.1
        Name = 'JXLEffort',
        Notes = 'values range from 1=low to 9=high',
        Writable = 'int32u',
        WriteGroup = 'IFD0',
    },
    [0xcd4b] = { -- DNG 1.7.1
        Name = 'JXLDecodeSpeed',
        Notes = 'values range from 1=slow to 4=fast',
        Writable = 'int32u',
        WriteGroup = 'IFD0',
    },
    [0xcea1] = {
        Name = 'SEAL', -- (writable directory!)
        Writable = 'string',
        WriteGroup = 'IFD0',
        SubDirectory = { TagTable = 'lexiftool.XMP.SEAL' },
        WriteCheck = function() return 'Can only delete' end, -- (don't allow writing)
    },
    [0xea1c] = { --13
        Name = 'Padding',
        Binary = 1,
        Protected = 1,
        Writable = 'undef',
        -- must start with 0x1c 0xea by the WM Photo specification
        -- (not sure what should happen if padding is only 1 byte)
        -- (why does MicrosoftPhoto write "1c ea 00 00 00 08"?)
        RawConvInv = function(_self, val) return perl.subst(perlStr(val), '^..', '\\x1c\\xea', 's') end,
    },
    [0xea1d] = {
        Name = 'OffsetSchema',
        Notes = "Microsoft's ill-conceived maker note offset difference",
        Protected = 1,
        Writable = 'int32s',
        -- From the Microsoft documentation:
        --
        --     Any time the "Maker Note" is relocated by Windows, the Exif MakerNote
        --     tag (37500) is updated automatically to reference the new location. In
        --     addition, Windows records the offset (or difference) between the old and
        --     new locations in the Exif OffsetSchema tag (59933). If the "Maker Note"
        --     contains relative references, the developer can add the value in
        --     OffsetSchema to the original references to find the correct information.
        --
        -- My recommendation is for other developers to ignore this tag because the
        -- information it contains is unreliable. It will be wrong if the image has
        -- been subsequently edited by another application that doesn't recognize the
        -- new Microsoft tag.
        --
        -- The new tag unfortunately only gives the difference between the new maker
        -- note offset and the original offset. Instead, it should have been designed
        -- to store the original offset. The new offset may change if the image is
        -- edited, which will invalidate the tag as currently written. If instead the
        -- original offset had been stored, the new difference could be easily
        -- calculated because the new maker note offset is known.
        --
        -- I exchanged emails with a Microsoft technical representative, pointing out
        -- this problem shortly after they released the update (Feb 2007), but so far
        -- they have taken no steps to address this.
    },
    -- tags in the range 0xfde8-0xfe58 have been observed in PS7 files
    -- generated from RAW images.  They are all strings with the
    -- tag name at the start of the string.  To accommodate these types
    -- of tags, all tags with values above 0xf000 are handled specially
    -- by ProcessExif().
    [0xfde8] = {
        Name = 'OwnerName',
        Condition = function(self) return self.TIFF_TYPE ~= 'DCR' end, -- (used for another purpose in Kodak DCR images)
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return "Owner's Name: " .. val end,
        Notes = [[
            tags 0xfde8-0xfdea and 0xfe4c-0xfe58 are generated by Photoshop Camera RAW.
            Some names are the same as other EXIF tags, but ExifTool will avoid writing
            these unless they already exist in the file
        ]],
    },
    [0xfde9] = {
        Name = 'SerialNumber',
        Condition = function(self) return self.TIFF_TYPE ~= 'DCR' end, -- (used for another purpose in Kodak DCR SubIFD)
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return 'Serial Number: ' .. val end,
    },
    [0xfdea] = {
        Name = 'Lens',
        Condition = function(self) return self.TIFF_TYPE ~= 'DCR' end, -- (used for another purpose in Kodak DCR SubIFD)
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return 'Lens: ' .. val end,
    },
    [0xfe4c] = {
        Name = 'RawFile',
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return 'Raw File: ' .. val end,
    },
    [0xfe4d] = {
        Name = 'Converter',
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return 'Converter: ' .. val end,
    },
    [0xfe4e] = {
        Name = 'WhiteBalance',
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return 'White Balance: ' .. val end,
    },
    [0xfe51] = {
        Name = 'Exposure',
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return 'Exposure: ' .. val end,
    },
    [0xfe52] = {
        Name = 'Shadows',
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return 'Shadows: ' .. val end,
    },
    [0xfe53] = {
        Name = 'Brightness',
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return 'Brightness: ' .. val end,
    },
    [0xfe54] = {
        Name = 'Contrast',
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return 'Contrast: ' .. val end,
    },
    [0xfe55] = {
        Name = 'Saturation',
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return 'Saturation: ' .. val end,
    },
    [0xfe56] = {
        Name = 'Sharpness',
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return 'Sharpness: ' .. val end,
    },
    [0xfe57] = {
        Name = 'Smoothness',
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return 'Smoothness: ' .. val end,
    },
    [0xfe58] = {
        Name = 'MoireFilter',
        Avoid = 1,
        PSRaw = 1,
        Writable = 'string',
        ValueConv = function(_self, val) return perl.subst(perlStr(val), '^.*: ', '') end,
        ValueConvInv = function(_self, val) return 'Moire Filter: ' .. val end,
    },
    ---------------
    [0xfe00] = {
        Name = 'KDC_IFD',
        Groups = { [1] = 'KDC_IFD' },
        Flags = 'SubIFD',
        Notes = 'used in some Kodak KDC images',
        SubDirectory = {
            TagTable = 'lexiftool.Kodak.KDC_IFD',
            DirName = 'KDC_IFD',
            Start = function(_self, val, _start) return val end,
        },
    },
}

-- indices for R, G, G and B components in input value (upstream @rggbLookup)
local rggbLookup = {
    { 0, 1, 2, 3 }, -- 0 RGGB
    { 0, 1, 3, 2 }, -- 1 RGBG
    { 0, 2, 3, 1 }, -- 2 RBGG
    { 1, 0, 3, 2 }, -- 3 GRBG
    { 1, 0, 2, 3 }, -- 4 GRGB
    { 2, 3, 0, 1 }, -- 5 GBRG
    { 0, 1, 1, 2 }, -- 6 RGB
    { 1, 0, 0, 2 }, -- 7 GRB
    { 0, 256, 256, 1 }, -- 8 RB (green level is 256)
}

-- Calculate Red/BlueBalance (upstream Exif.pm RedBlueBalance)
-- Inputs: 0) blue (0=red, 1=blue), 1) val (the composite's 0-based Desire
--         table: WB_xxxLevels strings at indices 0-8, WBRed/BlueLevel at 9,
--         WBGreenLevel at 10)
-- upstream GetLensInfo: extract short/long focal length and wide/tele max
-- aperture from a lens name string (e.g. "Sigma AF 10-20mm F4-5.6 EX DC" ->
-- 10, 20, 4, 5.6). Returns nil if the string doesn't have the expected
-- "NN[-NN]mm ... F/N.N[-N.N]" shape.
-- Inputs: 0) lens string, 1) flag to allow unknown "?" values
-- (Lua: the numbers come back as numbers, an unknown "?" as 'undef')
local function GetLensInfo(lens, unk)
    -- extract focal length and aperture ranges for this lens
    local pat = [[\d+(?:\.\d+)?]]
    if unk then pat = pat .. [[|\?]] end
    local sf, lf, sa, la = perl.matchesDyn(lens,
        '(' .. pat .. ')(?:-(' .. pat .. '))?\\s*mm.*?(?:[fF]\\/?\\s*)(' .. pat .. ')(?:-(' .. pat .. '))?')
    if not sf then return nil end
    -- ($1=short focal, $2=long focal, $3=max aperture wide, $4=max aperture tele)
    local a = { sf, lf, sa, la }
    if not perlTruthy(a[2]) then a[2] = a[1] end
    if not perlTruthy(a[4]) then a[4] = a[3] end
    for i = 1, 4 do
        if unk and a[i] == '?' then a[i] = 'undef' else a[i] = tonumber(a[i]) end
    end
    return a[1], a[2], a[3], a[4]
end
Exif.GetLensInfo = GetLensInfo

--------------------------------------------------------------------------------
-- Match lens in list of possbilities based on value of LensModel
-- Inputs: 0) reference to list of possible models, 1) LensModel string
-- - updates list on return; guaranteed not to remove all list entries
local function MatchLensModel(try, lensModel)
    -- (`@$try = @filt`: the caller's list is updated in place)
    local function set(filt)
        if #filt > 0 and #filt < #try then
            for i = #try, 1, -1 do try[i] = nil end
            for i = 1, #filt do try[i] = filt[i] end
        end
    end
    if #try > 1 and perlTruthy(lensModel) then
        local filt
        -- filter by focal length
        local focal = matches(lensModel, [[((\d+-)?\d+mm)]])
        if focal then
            filt = {}
            for _, t in ipairs(try) do if perl.isMatchDyn(t, focal) then filt[#filt + 1] = t end end
            set(filt)
        end
        -- filter by aperture
        local fnum = #try > 1 and matches(lensModel, [[(?i)(?:F/?|1:)(\d+(\.\d+)?)]])
        if fnum then
            filt = {}
            for _, t in ipairs(try) do
                if perl.isMatchDyn(t, '(?i)(F/?|1:)' .. fnum .. [[(\b|[A-Z])]]) then filt[#filt + 1] = t end
            end
            set(filt)
        end
        -- filter by model version, and other lens parameters
        for _, pat in ipairs({ 'I+', 'USM' }) do
            local ok, val = false, nil
            if #try > 1 then ok, val = perl.isMatchDyn(lensModel, [[\b(]] .. pat .. [[)\b]]) end
            if ok then
                filt = {}
                for _, t in ipairs(try) do
                    if perl.isMatchDyn(t, [[\b]] .. val .. [[\b]]) then filt[#filt + 1] = t end
                end
                set(filt)
            end
        end
    end
end
Exif.MatchLensModel = MatchLensModel

--------------------------------------------------------------------------------
-- Attempt to identify the specific lens if multiple lenses have the same LensType
-- Inputs: 0) ExifTool ref, 1) LensType print value, 2) PrintConv hash ref,
--         3) LensSpec print value, 4) LensType numerical value,
--         5) FocalLength, 6) MaxAperture, 7) MaxApertureValue, 8) MinFocalLength,
--         9) MaxFocalLength, 10) LensModel, 11) LensFocalRange, 12) LensSpec
-- (a Perl hash key is a string; a port lookup table may carry a key as a
--  number or as its string, so `$$printConv{...}` lookups go through `pcv`)
local sonyEtype
local function PrintLensID(et, lensTypePrt, printConv, lensSpecPrt, lensType, focalLength,
                           maxAperture, maxApertureValue, shortFocal, longFocal, lensModel,
                           lensFocalRange, _lensSpec)
    -- this logic relies on the LensType lookup:
    if lensType == nil then return nil end
    -- get print conversion hash if necessary
    if not printConv then printConv = et.TAG_INFO.LensType and et.TAG_INFO.LensType.PrintConv end
    -- just copy LensType PrintConv value if it was a lens name
    -- (Olympus or Panasonic -- just exclude things like Nikon and Leaf LensType)
    -- (a list of conversions is a Lua table whose [1] is a table; a lookup
    --  hash may well have a [1] entry of its own)
    if not (type(printConv) == 'table' and type(printConv[1]) ~= 'table') then
        if type(printConv) == 'table' and type(printConv[1]) == 'table' then
            printConv = printConv[1]
            lensTypePrt = subst(perlStr(lensTypePrt), ';.*', '')
            lensType = subst(perlStr(lensType), ' .*', '')
        else
            lensTypePrt = perlStr(lensTypePrt)
            if matches(lensTypePrt, 'mm') then return lensTypePrt end
            if matches(lensTypePrt, [[(\d)\/F]]) then return (subst(lensTypePrt, [[(\d)\/F]], '$1mm F')) end
            return nil
        end
    end
    local function pcv(k)
        if k == nil then return nil end
        local v = printConv[k]
        if v == nil and type(k) == 'string' then v = printConv[tonumber(k)] end
        if v == nil then v = printConv[perlStr(k)] end
        return v
    end
    -- get LensSpec information if available (Sony)
    local sf0, lf0, sa0, la0
    if perlTruthy(lensSpecPrt) then
        sf0, lf0, sa0, la0 = GetLensInfo(lensSpecPrt)
        if not perlTruthy(sa0) then sf0 = nil end -- (make sure aperture isn't zero)
    end
    -- use MaxApertureValue if MaxAperture is not available
    if not perlTruthy(maxAperture) then maxAperture = maxApertureValue end
    if perlTruthy(lensFocalRange) then
        local s, l = matches(perlStr(lensFocalRange), [[^(\d+)(?: (?:to )?(\d+))?$]])
        if s then shortFocal, longFocal = s, (l and l ~= '' and l or s) end
    end
    if et.Make == 'SONY' then
        if perlStr(lensType) == '65535' then
            -- patch for manual lens (forum17379)
            if pcv(lensType) and not perlTruthy(focalLength) and perl.num(maxAperture) == 1 then return pcv(lensType) end
            -- handle Sony E-type lenses when LensType2 isn't valid (NEX/ILCE models only)
            if matches(et.Model, 'NEX|ILCE') then
                if not sonyEtype then
                    sonyEtype = {}
                    local index, did = nil, {}
                    local sonyLensTypes2 = require('lexiftool.Sony').sonyLensTypes2
                    local keys = {}
                    for k in pairs(sonyLensTypes2) do keys[#keys + 1] = k end
                    tsort(keys, function(a, b) return perl.lt(a, b) end)
                    for _, k in ipairs(keys) do
                        local lens = subst(perlStr(sonyLensTypes2[k]), ' or .*', '')
                        if not did[lens] then
                            local i
                            if index then i, index = '65535.' .. index, index + 1 else i, index = 65535, 1 end
                            sonyEtype[i] = lens
                            did[lens] = 1
                        end
                    end
                end
                printConv = sonyEtype
            end
        elseif perl.num(lensType) ~= 0xff00 then
            -- Patch for Metabones or other adapters on Sony E-mount cameras (ref Jos Roost)
            -- Metabones Canon EF to E-mount adapters add 0xef00, 0xbc00 or 0x7700 to the
            -- high byte for 2-byte Canon LensType values, so we need to adjust for these.
            -- Offset 0xef00 is also used by Sigma MC-11, Fotodiox and Viltrox EF-E adapters.
            -- Have to exclude A-mount Sigma Filtermatic with 'odd' LensType=0xff00.
            local lt = perl.int(lensType)
            if require('lexiftool.Minolta').metabonesID[lt & 0xff00] then
                lensType = lt - (lt >= 0xef00 and 0xef00 or (lt >= 0xbc00 and 0xbc00 or 0x7700))
                printConv = require('lexiftool.Canon').canonLensTypes
                if pcv(lensType) then lensTypePrt = pcv(lensType) end
            -- Test for Sigma MC-11 SA-E adapter with Sigma SA lens using 0x4900 offset.
            -- (upper limit of test cuts off two highest Sigma lenses, but prevents
            -- conflict with old Minolta 25xxx and higher ID's)
            elseif lt >= 0x4900 and lt <= 0x590a then
                lensType = lt - 0x4900
                printConv = require('lexiftool.Sigma').sigmaLensTypes
                if pcv(lensType) then lensTypePrt = pcv(lensType) end
            end
        end
    -- (Min/MaxFocalLength may report the current focal length for Tamron zoom lenses)
    elseif perlTruthy(shortFocal) and perlTruthy(longFocal) and
           (not perlTruthy(lensModel) or not matches(lensModel, [[^TAMRON.*-\d+mm]])) then
        -- Canon (and some other makes) include makernote information
        -- which allows better lens identification
        return require('lexiftool.Canon').PrintLensID(printConv, lensType,
                    shortFocal, longFocal, maxAperture, lensModel)
    end
    local lens = pcv(lensType)
    if not lens then
        if perlTruthy(lensModel) then return lensModel end
        return lensTypePrt
    end
    if not pcv(perlStr(lensType) .. '.1') then return lens end
    lens = subst(lens, [[(?s) or .*]], '')    -- remove everything after "or"
    -- make list of all possible matching lenses
    local lenses = { lens }
    local i = 1
    while pcv(perlStr(lensType) .. '.' .. i) do
        lenses[#lenses + 1] = pcv(perlStr(lensType) .. '.' .. i)
        i = i + 1
    end
    -- attempt to determine actual lens
    local userLens = ExifTool.userLens or {}
    local matches_, best, user, diff = {}, {}, {}, nil
    focalLength, maxAperture = perl.num(focalLength), perl.num(maxAperture)
    for _, l in ipairs(lenses) do
        if userLens[l] then user[#user + 1] = l end
        -- sf = short focal
        -- lf = long focal
        -- sa = max aperture at short focal
        -- la = max aperture at long focal
        local sf, lf, sa, la = GetLensInfo(l)
        if not sf then goto continue end
        -- check against LensSpec parameters if available
        if sf0 then
            if math.abs(sf - sf0) > 0.5 or math.abs(sa - sa0) > 0.15 or
               math.abs(lf - lf0) > 0.5 or math.abs(la - la0) > 0.15 then goto continue end
            -- the basic parameters match, but also check against additional lens features:
            -- for Sony A and E lenses, the full LensSpec string should match with end of LensType,
            -- excluding any part between () at the end, and preceded by a space (the space
            -- ensures that e.g. Zeiss Loxia 21mm having LensSpec "E 21mm F2.8" will not be
            -- identified as "Sony FE 21mm F2.8 (SEL28F20 + SEL075UWC)")
            if perlTruthy(lensSpecPrt) and perl.isMatchDyn(l, ' \\Q' .. lensSpecPrt .. '\\E( \\(| GM$|$)') then
                best = { l }
                break
            end
            -- exactly-matching Sony lens should have been found above, so only add non-Sony lenses
            if not matches(l, '^Sony ') then best[#best + 1] = l end
            goto continue
        end
        do
            -- adjust focal length and aperture if teleconverter is attached (Minolta)
            local tc = matches(l, [[ \+ .*? (\d+(\.\d+)?)x( |$)]])
            if tc then
                tc = perl.num(tc)
                sf = sf * tc; lf = lf * tc
                sa = sa * tc; la = la * tc
            end
            -- see if we can rule out this lens using FocalLength and MaxAperture
            if focalLength ~= 0 then
                if focalLength < sf - 0.5 then goto continue end
                if focalLength > lf + 0.5 then goto continue end
            end
            if maxAperture ~= 0 then
                -- it seems that most manufacturers set MaxAperture and MaxApertureValue
                -- to the maximum aperture (smallest F number) for the current focal length
                -- of the lens, so assume that MaxAperture varies with focal length and find
                -- the closest match (this is somewhat contrary to the EXIF specification which
                -- states "The smallest F number of the lens", without mention of focal length)
                if maxAperture < sa - 0.15 then goto continue end -- (0.15 is arbitrary)
                if maxAperture > la + 0.15 then goto continue end
                -- now determine the best match for this aperture
                local aa -- approximate maximum aperture at this focal length
                if sf == lf or sa == la or focalLength <= sf then
                    -- either 1) prime lens, 2) fixed-aperture zoom, or 3) zoom at min focal
                    aa = sa
                elseif focalLength >= lf then
                    aa = la
                else
                    -- assume a log-log variation of max aperture with focal length
                    -- (see http://regex.info/blog/2006-10-05/263)
                    aa = math.exp(math.log(sa) + (math.log(la) - math.log(sa)) / (math.log(lf) - math.log(sf)) *
                                         (math.log(focalLength) - math.log(sf)))
                    -- a linear relationship between 1/FocalLength and 1/MaxAperture fits Sony better (ref 27)
                    --$aa = 1 / (1/$sa + (1/$focalLength - 1/$sf) * (1/$la - 1/$sa) / (1/$lf - 1/$sf));
                end
                local d = math.abs(maxAperture - aa)
                if diff ~= nil then
                    if d > diff + 0.15 then goto continue end -- (0.15 is arbitrary)
                    if d < diff - 0.15 then best = {} end
                end
                diff = d
                best[#best + 1] = l
            end
            matches_[#matches_ + 1] = l
        end
        ::continue::
    end
    -- return the user-defined lens if it exists
    if #user > 0 then
        -- choose the best match if we have more than one
        if #user > 1 then
            for _, try in ipairs({ best, matches_ }) do
                local good = {}
                for _, t in ipairs(try) do if userLens[t] then good[#good + 1] = t end end
                if #good > 0 then return table.concat(good, ' or ') end
            end
        end
        return table.concat(user, ' or ')
    end
    -- return the best match(es) from the possible lenses, after checking against LensModel
    if #best == 0 then best = matches_ end
    if #best > 0 then
        MatchLensModel(best, lensModel)
        return table.concat(best, ' or ')
    end
    lens = pcv(lensType)
    if perlTruthy(lensModel) and matches(lens, ' or ') then return lensModel end -- (eg. Sony NEX-5N)
    return lens
end
Exif.PrintLensID = PrintLensID

local function RedBlueBalance(blue, val)
    local rtnVal
    local pos = 0
    for i = 1, #rggbLookup do
        local levels = val[pos]
        pos = pos + 1
        if levels then
            local parts = {}
            for n in perlStr(levels):gmatch('[^ \t\n\r\f\v]+') do parts[#parts + 1] = tonumber(n) end
            if #parts >= 2 then
                local lookup = rggbLookup[i]
                local g = lookup[1 + 1] -- $$lookup[1]
                local skip = false
                if g < 4 then
                    if #parts < 3 then
                        skip = true
                    else
                        g = ((parts[g + 1] or 0) + (parts[lookup[2 + 1] + 1] or 0)) / 2
                        if g == 0 then skip = true end
                    end
                -- (an index past the end of @levels is undef in Perl, which
                --  numifies to 0 in both the comparison and the division --
                --  e.g. Leaf's 3-value WB_GRGBLevels, where $$lookup[3] is 3)
                elseif (parts[lookup[blue * 3 + 1] + 1] or 0) < 4 then
                    g = 1 -- Some Nikon cameras use a scaling factor of 1 (E5700)
                end
                if not skip then
                    rtnVal = (parts[lookup[blue * 3 + 1] + 1] or 0) / g
                    break
                end
            end
        end
    end
    -- upstream consumes @_ via `shift` inside the loop above, so the
    -- fallback's `$_[0]/$_[1]` are whatever's left after those shifts --
    -- i.e. the WBRed/BlueLevel,WBGreenLevel pair at Desire indices 9/10,
    -- not literally val[0]/val[1] (which are WB_RGGBLevels et al, already
    -- consumed by the loop above); `pos` tracks that same consumption here.
    if rtnVal == nil and val[pos] and val[pos + 1] then
        local a, b = tonumber(val[pos]), tonumber(val[pos + 1])
        if a and a ~= 0 and b then rtnVal = a / b end
    end
    return rtnVal
end

-- EXIF Composite tags (port of %Image::ExifTool::Exif::Composite, subset).
-- The upstream Composite table is merged into Image::ExifTool::Composite, so
-- group 0/1 default to 'Composite' and the tag IDs carry the 'Exif-' prefix.
--------------------------------------------------------------------------------
-- Extract image from file
-- Inputs: 0) ExifTool object reference, 1) data offset (in file), 2) data length
--         3) [optional] tag name
-- Returns: Reference to Image if specifically requested or "Binary data" message
--          Returns undef if there was an error loading the image
-- (Exif.pm:6216-6246. Both kinds of result come back as a SCALAR-ref
--  tuple, `{ ref = 'SCALAR', value = ... }`, the port's form of `\$image`;
--  ExtractBinary already returns its "Binary data" placeholder that way.)
local function ExtractImage(et, offset, len, tag)
    offset = tonumber(offset)
    len = tonumber(len)
    local dataPt = et.EXIF_DATA
    local dataPos = et.EXIF_POS
    local image

    -- no image if length is zero, and don't try to extract binary from XMP file
    if not perlTruthy(len) or et.FILE_TYPE == 'XMP' then return nil end

    -- take data from EXIF block if possible
    if dataPos ~= nil and dataPt ~= nil and offset >= dataPos and offset + len <= dataPos + #dataPt then
        image = substr(dataPt, offset - dataPos, len)
    else
        image = et:ExtractBinary(offset, len, tag)
        if image == nil then return nil end
        -- patch for incorrect ThumbnailOffset in some Sony DSLR-A100 ARW images
        if tag and tag == 'ThumbnailImage' and et.TIFF_TYPE == 'ARW' and
            et.Model == 'DSLR-A100' and offset < 0x10000 and
            not matches(image, [[^(Binary data|\xff\xd8\xff)]])
        then
            local try = et:ExtractBinary(offset + 0x10000, len, tag)
            if try ~= nil and isMatch(try, [[^\xff\xd8\xff]]) then
                image = try
                et.VALUE.ThumbnailOffset = et.VALUE.ThumbnailOffset + 0x10000
                et:Warn('Adjusted incorrect A100 ThumbnailOffset', 1)
            end
        end
    end
    image = et:ValidateImage(image, tag)
    if image == nil then return nil end
    return { ref = 'SCALAR', value = image }
end
Exif.ExtractImage = ExtractImage

--------------------------------------------------------------------------------
-- Translate date into standard EXIF format
-- Inputs: 0) date
-- Returns: date in format '2003:10:22'
-- - bad formats recognized: '2003-10-22','2003/10/22','2003 10 22','20031022'
-- - removes null terminator if it exists
--------------------------------------------------------------------------------
function Exif.ExifDate(date)
    date = subst(date, [[\0$]], '')       -- remove any null terminator
    -- separate year:month:day with colons
    -- (have seen many other characters, including nulls, used erroneously)
    date = subst(date, [[(\d{4})[^\d]*(\d{2})[^\d]*(\d{2})$]], '$1:$2:$3')
    return date
end

--------------------------------------------------------------------------------
-- Translate time into standard EXIF format
-- Inputs: 0) time
-- Returns: time in format '10:30:55'
-- - bad formats recognized: '10 30 55', '103055', '103055+0500'
-- - removes null terminator if it exists
-- - leaves time zone intact if specified (eg. '10:30:55+05:00')
--------------------------------------------------------------------------------
function Exif.ExifTime(time)
    time = tr(time, ' ', ':')   -- use ':' (not ' ') as a separator
    time = subst(time, [[\0$]], '')   -- remove any null terminator
    -- add separators if they don't exist
    time = subst(time, [[^(\d{2})(\d{2})(\d{2})]], '$1:$2:$3')
    time = subst(time, [[([+-]\d{2})(\d{2})\s*$]], '$1:$2')   -- to timezone too
    return time
end

--------------------------------------------------------------------------------
-- Generate TIFF file from scratch (in current byte order)
-- Inputs: 0) hash of IFD entries (TagID => Value; multiple values space-delimited)
--         1) raw image data reference
-- Returns: TIFF image data, or undef on error
-- (Exif.pm:6101-6131; the data string instead of a reference)
local function GenerateTIFF(entries, data)
    local offsetPos

    -- (upstream sorts `keys %$entries` numerically; the Lua keys are
    --  collected first, since pairs() order is undefined)
    local tags = {}
    for tag in pairs(entries) do tags[#tags + 1] = tag end
    tsort(tags)
    local num = #tags
    local ifdBuff = ExifTool.GetByteOrder() .. ExifTool.Put16u(42) .. ExifTool.Put32u(8) .. ExifTool.Put16u(num)
    local valBuff = ''
    local tagTablePtr = ExifTool.GetTagTable(nil, 'lexiftool.Exif.Main')
    for _, tag in ipairs(tags) do
        local tagInfo = tagTablePtr[tag]
        -- (`ref $tagInfo eq 'HASH'`: a conditional list is a Lua array)
        local fmt
        if type(tagInfo) == 'table' and tagInfo[1] == nil then
            fmt = tagInfo.Writable
        else
            fmt = 'int32u'
        end
        if fmt == nil then return nil end
        local val = require('lexiftool.Writer').WriteValue(entries[tag], fmt, -1)
        if val == nil then return nil end
        local format = Exif.formatNumber[fmt]
        ifdBuff = ifdBuff .. ExifTool.Put16u(tag) .. ExifTool.Put16u(format) ..
                  ExifTool.Put32u(#val // Exif.formatSize[format])
        if tag == 0x111 then offsetPos = #ifdBuff end -- (remember StripOffsets position)
        if #val > 4 then
            ifdBuff = ifdBuff .. ExifTool.Put32u(10 + 12 * num + 4 + #valBuff)
            valBuff = valBuff .. val
        else
            if #val < 4 then val = val .. string.rep('\0', 4 - #val) end
            ifdBuff = ifdBuff .. val
        end
    end
    ifdBuff = ifdBuff .. '\0\0\0\0' -- (no IFD1)
    if not offsetPos then return nil end
    -- (upstream `Set32u(VAL, \$ifdBuff, $offsetPos)` writes in place,
    --  which needs the mutable buffer here)
    local ifdBuf = require('carray').new('char')
    ifdBuf:append(ifdBuff)
    ExifTool.Set32u(ifdBuf, offsetPos, #ifdBuff + #valBuff)
    return ifdBuf:tostring() .. valBuff .. data
end

--------------------------------------------------------------------------------
-- Rebuild TIFF thumbnail(s)/preview(s) into stand-alone files with current byte order
-- Inputs: 0) ExifTool ref, 1) SubfileType, 2) Compression, 3) ImageWidth, 4) ImageHeight,
--         5) BitsPerSample, 6) PhotometricInterpretation, 7) StripOffsets, 8) SamplesPerPixel,
--         9) RowsPerStrip, 10) StripByteCounts, 10) PlanarConfiguration, 11) Orientation
-- Returns: 0) TIFF image or undef, 1/2) Family 0/1 groups for TIFF preview IFD
-- (Exif.pm:6139-6208; the Require/Desire values are not read, as upstream.
--  The image comes back as the data string, not a reference, and the
--  groups always as the 2nd/3rd return value -- Lua has no wantarray.
--  `next SubFile` is a goto to the end of the loop body.)
local function RebuildTIFF(et)
    local value = et.VALUE
    local rtn, grp0, grp1
    if et.FILE_TYPE == 'RWZ' then return nil end
    local i = 0
    while true do
        local key = 'SubfileType' .. (i ~= 0 and (' (' .. i .. ')') or '')
        if value[key] == nil then break end
        if tonumber(value[key]) ~= 1 then goto nextSubFile end -- (reduced-resolution image)
        do
            local grp = et:GetGroup(key, 1)
            local cmp = et:FindValue('Compression', grp)
            if tonumber(cmp) ~= 1 then goto nextSubFile end -- (no compression)
            local vals = { Compression = cmp, PlanarConfiguration = 1, Orientation = 1 }
            for _, t in ipairs({ 'ImageWidth', 'ImageHeight', 'BitsPerSample', 'PhotometricInterpretation',
                                 'StripOffsets', 'SamplesPerPixel', 'RowsPerStrip', 'StripByteCounts',
                                 'PlanarConfiguration', 'Orientation' })
            do
                local val = et:FindValue(t, grp)
                if val ~= nil then
                    vals[t] = val
                elseif vals[t] == nil then
                    goto nextSubFile
                end
            end
            local w, h = tonumber(vals.ImageWidth), tonumber(vals.ImageHeight)
            local bits = perl.split(' ', perlStr(vals.BitsPerSample))
            local rowBytes = 0
            -- (`int(($_+7)/8)`: floor division, the bit counts are not negative)
            for _, b in ipairs(bits) do rowBytes = rowBytes + w * ((tonumber(b) + 7) // 8) end
            local dat = ''
            local off = perl.split(' ', perlStr(vals.StripOffsets))
            local len = perl.split(' ', perlStr(vals.StripByteCounts))
            -- read the image data
            for j = 1, #off do
                if tonumber(len[j]) ~= rowBytes * vals.RowsPerStrip then goto nextSubFile end
                local tmp = et:ExtractBinary(tonumber(off[j]), tonumber(len[j]))
                if tmp == nil then goto nextSubFile end
                dat = dat .. tmp
            end
            -- generate the TIFF image
            local entries = {
                [0x0fe] = 0,                 -- SubfileType = 0
                [0x100] = w,                 -- ImageWidth
                [0x101] = h,                 -- ImageHeight
                [0x102] = vals.BitsPerSample,-- BitsPerSample
                [0x103] = vals.Compression,  -- Compression
                [0x106] = vals.PhotometricInterpretation, -- PhotometricInterpretation
                [0x111] = 0,                 -- StripOffsets (will be adjusted later)
                [0x112] = vals.Orientation,  -- Orientation
                [0x115] = vals.SamplesPerPixel, -- SamplesPerPixel
                [0x116] = h,                 -- RowsPerStrip
                [0x117] = h * rowBytes,      -- StripByteCounts
                [0x11a] = 72,                -- XResolution = 72
                [0x11b] = 72,                -- YResolution = 72
                [0x11c] = vals.PlanarConfiguration, -- PlanarConfiguration
                [0x128] = 2,                 -- ResolutionUnit = 2
            }
            local img = GenerateTIFF(entries, dat)

            if img == nil then
                et:Warn('Invalid ' .. (w > 256 and 'Preview' or 'Thumbnail') .. 'TIFF data')
            elseif rtn or w > 256 then -- (call it a preview if larger than 256 pixels)
                et:FoundTag('PreviewTIFF', { ref = 'SCALAR', value = img }, et:GetGroup(key, 0), et:GetGroup(key, 1))
            else
                rtn = img
                grp0, grp1 = et:GetGroup(key, 0), et:GetGroup(key, 1)
            end
        end
        ::nextSubFile::
        i = i + 1
    end
    return rtn, grp0, grp1
end

-- shared value computation for SubSecDateTimeOriginal/SubSecCreateDate/
-- SubSecModifyDate (upstream %subSecConv's RawConv, ported in full -- its
-- return value IS the composite's raw value; BuildCompositeTags now uses a
-- RawConv result as the value when no ValueConv exists)
-- Inputs: val array: 0) date/time, 1) sub-seconds, 2) time zone offset
local function subSecConv(val)
    -- upstream: `my $v;` starts undefined and is only ever assigned inside
    -- the two conditional blocks below -- if neither subSec nor a time
    -- zone offset is available, $v (and so the whole composite) stays
    -- undefined, matching "return undef unless defined $value"
    local v
    local base = val[0] and perlStr(val[0])
    local subSecStr = val[1] and perlStr(val[1])
    if base and subSecStr then
        local subSec = matches(subSecStr, [[^(\d+)]])
        if subSec then
            local newV, n = base:gsub('( %d%d:%d%d:%d%d)$', '%1.' .. subSec)
            if n > 0 then v = newV end
        end
    end
    local offsetStr = val[2] and perlStr(val[2])
    if offsetStr and base and not matches(base, '[-+]') then
        local sign, hh, mm = matches(offsetStr, [[^([-+])(\d{1,2}):(\d{2})]])
        if sign then
            v = (v or base) .. sprintf('%s%.2d:%.2d', sign, tonumber(hh), tonumber(mm))
        end
    end
    return v
end

Exif.Composite = {
    GROUPS = { [2] = 'Image' },
    ThumbnailImage = {
        TagID = 'Exif-ThumbnailImage',
        Groups = { [0] = 'EXIF', [1] = 'IFD1', [2] = 'Preview' },
        Writable = 1,
        WriteGroup = 'All',
        WriteCheck = function(self, _tagInfo, val) return self:CheckImage(val) end,
        WriteAlso = {
            -- (the 0xfeedfeed values are translated in the Exif write routine)
            ThumbnailOffset = function(_self, val) if val ~= nil then return 0xfeedfeed end return nil end,
            ThumbnailLength = function(_self, val) if val ~= nil then return 0xfeedfeed end return nil end,
        },
        Require = { [0] = 'ThumbnailOffset', [1] = 'ThumbnailLength' },
        Notes = [[
            this tag is writable, and may be used to update existing thumbnails, but may
            only create a thumbnail in IFD1 of certain types of files.  Note that for
            this and other Composite embedded-image tags the family 0 and 1 groups match
            those of the originating tags
        ]],
        -- retrieve the thumbnail from our EXIF data
        RawConv = function(self, val, _tag, valKeys)
            local img = ExtractImage(self, val[0], val[1], 'ThumbnailImage')
            if img == nil then return nil end
            -- set groups from ThumbnailOffsets
            self.SET_GROUP0 = self:GetGroup(valKeys[0], 0)
            self.SET_GROUP1 = self:GetGroup(valKeys[0], 1)
            return img
        end,
    },
    PreviewImage = {
        TagID = 'Exif-PreviewImage',
        Groups = { [0] = 'EXIF', [1] = 'SubIFD', [2] = 'Preview' },
        Writable = 1,
        WriteGroup = 'All',
        WriteCheck = function(self, _tagInfo, val) return self:CheckImage(val) end,
        DelCheck = function(_self) return nil, '' end, -- can't delete, so set to empty string
        WriteAlso = {
            PreviewImageStart  = function(_self, val) if val ~= nil then return 0xfeedfeed end return nil end,
            PreviewImageLength = function(_self, val) if val ~= nil then return 0xfeedfeed end return nil end,
            PreviewImageValid  = function(_self, val) if val == nil then return '' end return length(val) > 0 and 1 or 0 end, -- (for Olympus)
        },
        Require = { [0] = 'PreviewImageStart', [1] = 'PreviewImageLength' },
        Desire = {
            [2] = 'PreviewImageValid',
            -- (DNG and A100 ARW may be have 2 preview images)
            [3] = 'PreviewImageStart (1)',
            [4] = 'PreviewImageLength (1)',
        },
        Notes = [[
            this tag is writable, and may be used to update existing embedded images,
            but not create or delete them
        ]],
        -- note: extract 2nd preview, but ignore double-referenced preview
        -- (in A100 ARW images, the 2nd PreviewImageLength from IFD0 may be wrong anyway)
        -- (port: `@grps = $self->GetGroup($$val{0})` sets SET_GROUP0/1 for the
        --  FoundTag that follows, once the image is there; the tag keys are
        --  the 4th argument)
        RawConv = function(self, val, _tag, valKeys)
            if perlTruthy(val[3]) and perlTruthy(val[4]) and perlStr(val[0]) ~= perlStr(val[3]) then
                local val_ = setmetatable({
                    [0] = 'PreviewImageStart (1)',
                    [1] = 'PreviewImageLength (1)',
                    [2] = 'PreviewImageValid',
                }, { __index = { ref = 'HASH' } })
                self:FoundTag(Exif.Composite.PreviewImage, val_)
            end
            if val[2] ~= nil and not perlTruthy(val[2]) then return nil end
            local img = ExtractImage(self, val[0], val[1], 'PreviewImage')
            if img == nil then return nil end
            self.SET_GROUP0 = self:GetGroup(valKeys[0], 0)
            self.SET_GROUP1 = self:GetGroup(valKeys[0], 1)
            return img
        end,
    },
    JpgFromRaw = {
        TagID = 'Exif-JpgFromRaw',
        Groups = { [0] = 'EXIF', [1] = 'SubIFD', [2] = 'Preview' },
        Writable = 1,
        WriteGroup = 'All',
        WriteCheck = function(self, _tagInfo, val) return self:CheckImage(val) end,
        -- Note: ExifTool 10.38 had disabled the ability to delete this -- why?
        -- --> added the DelCheck in 10.61 to re-enable this
        DelCheck = function(_self) return nil, '' end, -- can't delete, so set to empty string
        WriteAlso = {
            JpgFromRawStart  = function(_self, val) if val ~= nil then return 0xfeedfeed end return nil end,
            JpgFromRawLength = function(_self, val) if val ~= nil then return 0xfeedfeed end return nil end,
        },
        Require = { [0] = 'JpgFromRawStart', [1] = 'JpgFromRawLength' },
        Notes = [[
            this tag is writable, and may be used to update existing embedded images,
            but not create or delete them
        ]],
        RawConv = function(self, val, _tag, valKeys)
            local img = ExtractImage(self, val[0], val[1], 'JpgFromRaw')
            if img == nil then return nil end
            self.SET_GROUP0 = self:GetGroup(valKeys[0], 0)
            self.SET_GROUP1 = self:GetGroup(valKeys[0], 1)
            return img
        end,
    },
    OtherImage = {
        TagID = 'Exif-OtherImage',
        Groups = { [0] = 'EXIF', [1] = 'SubIFD', [2] = 'Preview' },
        Writable = 1,
        WriteGroup = 'All',
        WriteCheck = function(self, _tagInfo, val) return self:CheckImage(val) end,
        DelCheck = function(_self) return nil, '' end, -- can't delete, so set to empty string
        WriteAlso = {
            OtherImageStart  = function(_self, val) if val ~= nil then return 0xfeedfeed end return nil end,
            OtherImageLength = function(_self, val) if val ~= nil then return 0xfeedfeed end return nil end,
        },
        Require = {
            [0] = 'OtherImageStart',
            [1] = 'OtherImageLength',
        },
        Desire = {
            [2] = 'OtherImageStart (1)',
            [3] = 'OtherImageLength (1)',
        },
        Notes = [[
            this tag is writable, and may be used to update existing embedded images,
            but not create or delete them
        ]],
        -- retrieve all other images
        RawConv = function(self, val, _tag, valKeys)
            if perlTruthy(val[2]) and perlTruthy(val[3]) then
                local i = 1
                while true do
                    local val_ = setmetatable({ [0] = valKeys[2], [1] = valKeys[3] }, { __index = { ref = 'HASH' } })
                    self:FoundTag(Exif.Composite.OtherImage, val_)
                    i = i + 1
                    valKeys[2] = valKeys[0] .. ' (' .. i .. ')'
                    if self.VALUE[valKeys[2]] == nil then break end
                    valKeys[3] = valKeys[1] .. ' (' .. i .. ')'
                    if self.VALUE[valKeys[3]] == nil then break end
                end
            end
            local img = ExtractImage(self, val[0], val[1], 'OtherImage')
            if img == nil then return nil end
            self.SET_GROUP0 = self:GetGroup(valKeys[0], 0)
            self.SET_GROUP1 = self:GetGroup(valKeys[0], 1)
            return img
        end,
    },
    PreviewJXL = {
        TagID = 'Exif-PreviewJXL',
        Groups = { [0] = 'EXIF', [1] = 'SubIFD', [2] = 'Preview' },
        Require = {
            [0] = 'PreviewJXLStart',
            [1] = 'PreviewJXLLength',
        },
        Desire = {
            [2] = 'PreviewJXLStart (1)',
            [3] = 'PreviewJXLLength (1)',
        },
        -- retrieve all other JXL images
        RawConv = function(self, val, tag, valKeys)
            if perlTruthy(val[2]) and perlTruthy(val[3]) then
                local i = 1
                while true do
                    local val_ = setmetatable({ [0] = valKeys[2], [1] = valKeys[3] }, { __index = { ref = 'HASH' } })
                    self:FoundTag(Exif.Composite.PreviewJXL, val_)
                    i = i + 1
                    valKeys[2] = valKeys[0] .. ' (' .. i .. ')'
                    if self.VALUE[valKeys[2]] == nil then break end
                    valKeys[3] = valKeys[1] .. ' (' .. i .. ')'
                    if self.VALUE[valKeys[3]] == nil then break end
                end
            end
            self.SET_GROUP0 = self:GetGroup(valKeys[0], 0)
            self.SET_GROUP1 = self:GetGroup(valKeys[0], 1)
            local image = self:ExtractBinary(val[0], val[1], 'PreviewJXL')
            if not isMatch(image, [[(?s)^(Binary data|\xff\x0a|\0\0\0\x0cJXL \x0d\x0a......ftypjxl )]]) then
                self.SET_GROUP0, self.SET_GROUP1 = nil, nil
                self:Warn(perlStr(tag) .. ' is not a valid JXL image', 1)
                return nil
            end
            return { ref = 'SCALAR', value = image }
        end,
    },
    ThumbnailTIFF = {
        TagID = 'Exif-ThumbnailTIFF',
        Groups = { [2] = 'Preview' },
        Require = {
            [0] = 'SubfileType',
            [1] = 'Compression',
            [2] = 'ImageWidth',
            [3] = 'ImageHeight',
            [4] = 'BitsPerSample',
            [5] = 'PhotometricInterpretation',
            [6] = 'StripOffsets',
            [7] = 'SamplesPerPixel',
            [8] = 'RowsPerStrip',
            [9] = 'StripByteCounts',
        },
        Desire = {
            [10] = 'PlanarConfiguration',
            [11] = 'Orientation',
        },
        -- rebuild the TIFF thumbnail from our EXIF data
        RawConv = function(self, val)
            -- (upstream: `($tiff, @grps) = RebuildTIFF($self, @val)`; the
            --  groups of the matched SubfileType go to SET_GROUP0/1, this
            --  port's form of the RawConv's @grps)
            local tiff, grp0, grp1 = RebuildTIFF(self, val)
            if tiff == nil then return nil end
            self.SET_GROUP0, self.SET_GROUP1 = grp0, grp1
            return { ref = 'SCALAR', value = tiff }
        end,
    },
    ImageSize = {
        TagID = 'Exif-ImageSize',
        Require = { [0] = 'ImageWidth', [1] = 'ImageHeight' },
        Desire = { [2] = 'ExifImageWidth', [3] = 'ExifImageHeight', [4] = 'RawImageCroppedSize' }, -- (FujiFilm RAF images)
        ValueConv = function(self, val)
            if perlTruthy(val[4]) then return val[4] end
            if perlTruthy(val[2]) and perlTruthy(val[3]) and
                    isMatch(self.TIFF_TYPE, [[^(CR2|Canon 1D RAW|IIQ|EIP)$]]) then
                return perlStr(val[2]) .. ' ' .. perlStr(val[3])
            end
            if self.IsFloat(val[0]) and self.IsFloat(val[1]) then return perlStr(val[0]) .. ' ' .. perlStr(val[1]) end
            return nil
        end,
        PrintConv = function(_self, val) val = perl.tr(perlStr(val), ' ', 'x') return val end,
    },
    CFAPattern = {
        TagID = 'Exif-CFAPattern',
        Require = {
            [0] = 'CFARepeatPatternDim',
            [1] = 'CFAPattern2',
        },
        -- generate CFAPattern
        ValueConv = function(_self, val)
            local a = {}
            for v in perlStr(val[0]):gmatch('[^ \t\n\r\f\v]+') do a[#a + 1] = v end
            local b = {}
            for v in perlStr(val[1]):gmatch('[^ \t\n\r\f\v]+') do b[#b + 1] = v end
            if not (#a == 2 and #b == a[1] * a[2]) then return '?' end
            return a[1] .. ' ' .. a[2] .. ' ' .. table.concat(b, ' ')
        end,
        PrintConv = function(_self, val) return PrintCFAPattern(val) end,
    },
    Megapixels = {
        TagID = 'Exif-Megapixels',
        Require = { [0] = 'ImageSize' },
        -- upstream passes $val[0] (the first required value) as $val
        ValueConv = function(_self, val)
            local d = {}
            for m in perlStr(val[0]):gmatch('(%d+)') do d[#d + 1] = m end
            return tonumber(d[1]) * tonumber(d[2]) / 1000000
        end,
        PrintConv = function(_self, val)
            return sprintf('%.*f', (val >= 1 and 1 or (val >= 0.001 and 3 or 6)), val)
        end,
    },
    GPSPosition = {
        TagID = 'Exif-GPSPosition',
        Groups = { [2] = 'Location' },
        Writable = 1,
        Protected = 1,
        WriteAlso = {
            GPSLatitude = function(_self, val) if val ~= nil then local m = matches(val, [[(.*) ]]) if m then return m end end return nil end,
            GPSLatitudeRef = function(_self, val)
                if val ~= nil then
                    local ok, m = isMatch(val, [[(-?)(.*?) ]])
                    if ok then return perlTruthy(m) and "S" or "N" end
                end
                return nil
            end,
            GPSLongitude = function(_self, val) if val ~= nil then local m = matches(val, [[ (.*)$]]) if m then return m end end return nil end,
            GPSLongitudeRef = function(_self, val)
                if val ~= nil then
                    local ok, m = isMatch(val, [[ (-?)]])
                    if ok then return perlTruthy(m) and "W" or "E" end
                end
                return nil
            end,
        },
        PrintConvInv = function(_self, val)
            local ok, lat, lon = isMatch(val, [[(.*? ?[NS]?), ?(.*? ?[EW]?)$]])
            if not ok then
                ok, lat, lon = isMatch(val, [[^\s*(-?\d+(?:\.\d+)?)\s*(-?\d+(?:\.\d+)?)\s*$]])
            end
            if not ok then return nil end
            local GPS = require('lexiftool.GPS')
            lat = GPS.ToDegrees(lat, 1, "lat")
            lon = GPS.ToDegrees(lon, 1, "lon")
            return perlStr(lat) .. ' ' .. perlStr(lon)
        end,
        Require = {
            [0] = 'GPSLatitude',
            [1] = 'GPSLongitude',
        },
        Priority = 0,
        Notes = [[
            when written, writes GPSLatitude, GPSLatitudeRef, GPSLongitude and
            GPSLongitudeRef.  This tag may be written using the same coordinate
            format as provided by Google Maps when right-clicking on a location
        ]],
        ValueConv = function(_self, val)
            if perlTruthy(length(val[0])) or perlTruthy(length(val[1])) then
                return perlStr(val[0]) .. ' ' .. perlStr(val[1])
            end
            return nil
        end,
        PrintConv = function(_self, _val, _vals, prt) return perlStr(prt[0]) .. ', ' .. perlStr(prt[1]) end,
    },
    ShutterSpeed = {
        TagID = 'Exif-ShutterSpeed',
        Desire = {
            [0] = 'ExposureTime',
            [1] = 'ShutterSpeedValue',
            [2] = 'BulbDuration',
        },
        ValueConv = function(_self, val)
            local bulb = tonumber(val[2])
            if bulb and bulb > 0 then return bulb end
            if val[0] ~= nil then return val[0] end
            return val[1]
        end,
        PrintConv = function(_self, val) return PrintExposureTime(val) end,
    },
    Aperture = {
        TagID = 'Exif-Aperture',
        Desire = {
            [0] = 'FNumber',
            [1] = 'ApertureValue',
        },
        RawConv = function(_self, val)
            if perlTruthy(val[0]) or perlTruthy(val[1]) then return val end
            return nil
        end,
        ValueConv = function(_self, val)
            if perlTruthy(val[0]) then return val[0] end
            return val[1]
        end,
        PrintConv = function(_self, val) return PrintFNumber(val) end,
    },
    LightValue = {
        TagID = 'Exif-LightValue',
        Notes = [[
            calculated LV = 2 * log2(Aperture) - log2(ShutterSpeed) - log2(ISO/100);
            similar to exposure value but normalized to ISO 100
        ]],
        Require = {
            [0] = 'Aperture',
            [1] = 'ShutterSpeed',
            [2] = 'ISO',
        },
        ValueConv = function(_self, val, prt) return CalculateLV(val[0], val[1], prt[2]) end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
    },
    FocalLength35efl = { --#26/PH
        TagID = 'Exif-FocalLength35efl',
        Description = 'Focal Length 35mm Equiv',
        Notes = 'this value may be incorrect if the image has been resized',
        Groups = { [2] = 'Camera' },
        Require = { [0] = 'FocalLength' },
        Desire = { [1] = 'ScaleFactor35efl' },
        ValueConv = function(_self, val)
            -- upstream: `ToFloat(@val); ($val[0] || 0) * ($val[1] || 1)` --
            -- ToFloat coerces the leading numeric prefix of a string (a
            -- value like "8.6 mm" must read as 8.6, which tonumber() can't)
            local f0 = ExifTool.ToFloat(val[0]) or 0
            local f1 = ExifTool.ToFloat(val[1])
            return f0 * (f1 or 1)
        end,
        -- upstream PrintConv sees both $val (the ValueConv result) and
        -- @val (the raw Require/Desire inputs); our port's third PrintConv
        -- arg carries the same `val` table (see BuildCompositeTags)
        PrintConv = function(_self, v, val)
            if val and val[1] then
                return sprintf('%.1f mm (35 mm equivalent: %.1f mm)', tonumber(val[0]), v)
            end
            return sprintf('%.1f mm', v)
        end,
    },
    ScaleFactor35efl = { --#26/PH
        TagID = 'Exif-ScaleFactor35efl',
        Description = 'Scale Factor To 35 mm Equivalent',
        Notes = [[
            this value and any derived values may be incorrect if the image has been
            resized
        ]],
        Groups = { [2] = 'Camera' },
        Desire = {
            [0] = 'FocalLength',
            [1] = 'FocalLengthIn35mmFormat',
            [2] = 'Composite:DigitalZoom',
            [3] = 'FocalPlaneDiagonal',
            [4] = 'SensorSize',
            [5] = 'FocalPlaneXSize',
            [6] = 'FocalPlaneYSize',
            [7] = 'FocalPlaneResolutionUnit',
            [8] = 'FocalPlaneXResolution',
            [9] = 'FocalPlaneYResolution',
            [10] = 'ExifImageWidth',
            [11] = 'ExifImageHeight',
            [12] = 'CanonImageWidth',
            [13] = 'CanonImageHeight',
            [14] = 'ImageWidth',
            [15] = 'ImageHeight',
        },
        ValueConv = function(self, val) return CalcScaleFactor35efl(self, val) end,
        PrintConv = function(_self, val) return sprintf('%.1f', val) end,
    },
    CircleOfConfusion = {
        TagID = 'Exif-CircleOfConfusion',
        Notes = [[
            calculated as D/1440, where D is the focal plane diagonal in mm.  This value
            may be incorrect if the image has been resized
        ]],
        Groups = { [2] = 'Camera' },
        Require = { [0] = 'ScaleFactor35efl' },
        ValueConv = function(_self, val)
            local sf = tonumber(val[0])
            if not sf or sf == 0 then return nil end
            return math.sqrt(24 * 24 + 36 * 36) / (sf * 1440)
        end,
        PrintConv = function(_self, val) return sprintf('%.3f mm', val) end,
    },
    HyperfocalDistance = {
        TagID = 'Exif-HyperfocalDistance',
        Notes = 'this value may be incorrect if the image has been resized',
        Groups = { [2] = 'Camera' },
        Require = {
            [0] = 'FocalLength',
            [1] = 'Aperture',
            [2] = 'CircleOfConfusion',
        },
        ValueConv = function(_self, val)
            -- upstream runs `ToFloat(@val)` first, which rounds every value
            -- to Perl's 15 significant digits on the way through its own
            -- stringification -- the result differs in the last digit if the
            -- full double is used instead
            local f = ExifTool.ToFloat(val[0])
            local a = ExifTool.ToFloat(val[1])
            local c = ExifTool.ToFloat(val[2])
            if not (a and c) or a == 0 or c == 0 then return 'inf' end
            return f * f / (a * c * 1000)
        end,
        PrintConv = function(_self, val) return sprintf('%.2f m', val) end,
    },
    DOF = {
        TagID = 'Exif-DOF',
        Description = 'Depth Of Field',
        Notes = 'this value may be incorrect if the image has been resized',
        Require = {
            [0] = 'FocalLength',
            [1] = 'Aperture',
            [2] = 'CircleOfConfusion',
        },
        Desire = {
            [3] = 'FocusDistance', -- focus distance in metres (0 is infinity)
            [4] = 'SubjectDistance',
            [5] = 'ObjectDistance',
            [6] = 'ApproximateFocusDistance',
            [7] = 'FocusDistanceLower',
            [8] = 'FocusDistanceUpper',
        },
        ValueConv = function(_self, val)
            local v = {}
            for i = 0, 8 do v[i] = ExifTool.ToFloat(val[i]) end -- (ToFloat(@val))
            local d, f = v[3], v[0]
            if d ~= nil then
                if not perlTruthy(d) then d = 1e10 end -- (use large number for infinity)
            else
                d = perlTruthy(v[4]) and v[4] or perlTruthy(v[5]) and v[5] or v[6]
                if d == nil then
                    if v[7] == nil or v[8] == nil then return nil end
                    d = (v[7] + v[8]) / 2
                end
            end
            if not (perlTruthy(f) and perlTruthy(v[2])) then return 0 end
            local t = v[1] * v[2] * (d * 1000 - f) / (f * f)
            local r = { d / (1 + t), d / (1 - t) }
            if r[2] < 0 then r[2] = 0 end -- 0 means 'inf'
            return perl.join(' ', r)
        end,
        PrintConv = function(_self, val)
            val = perl.tr(perlStr(val), ',', '.') -- in case locale is whacky
            local v = perl.split(' ', val)
            if not perlTruthy(v[2]) then return sprintf('inf (%.2f m - inf)', v[1]) end
            local dof = perl.num(v[2]) - perl.num(v[1])
            local fmt = (dof > 0 and dof < 0.02) and '%.3f' or '%.2f'
            return sprintf(fmt .. ' m (' .. fmt .. ' - ' .. fmt .. ' m)', dof, v[1], v[2])
        end,
    },
    FOV = {
        TagID = 'Exif-FOV',
        Description = 'Field Of View',
        Notes = [[
            calculated for the long image dimension.  This value may be incorrect for
            fisheye lenses, or if the image has been resized
        ]],
        Require = {
            [0] = 'FocalLength',
            [1] = 'ScaleFactor35efl',
        },
        Desire = {
            [2] = 'FocusDistance', -- (multiply by 1000 to convert to mm)
        },
        -- ref http://www.bobatkins.com/photography/technical/field_of_view.html
        -- (calculations below apply to rectilinear lenses only, not fisheye)
        ValueConv = function(_self, val)
            local focal = ExifTool.ToFloat(val[0])
            local sf = ExifTool.ToFloat(val[1])
            if not (focal and focal ~= 0 and sf and sf ~= 0) then return nil end
            local corr = 1
            local fd = ExifTool.ToFloat(val[2])
            if fd and fd ~= 0 then
                local d = 1000 * fd - focal
                if d > 0 then corr = corr + focal / d end
            end
            local fd2 = math.atan(36, 2 * focal * sf * corr)
            -- (NumStr, not tostring: Perl stringifies with 15 significant
            --  digits, Lua with more)
            local fov = { ExifTool.NumStr(fd2 * 360 / 3.14159) }
            if fd and fd > 0 and fd < 10000 then
                fov[#fov + 1] = ExifTool.NumStr(2 * fd * math.sin(fd2) / math.cos(fd2))
            end
            return table.concat(fov, ' ')
        end,
        PrintConv = function(_self, val)
            local parts = {}
            for p in perlStr(val):gmatch('[^ \t\n\r\f\v]+') do parts[#parts + 1] = tonumber(p) end
            local str = sprintf('%.1f deg', parts[1])
            if parts[2] and parts[2] ~= 0 then
                str = str .. sprintf(' (%.2f m)', parts[2])
            end
            return str
        end,
    },
    -- generate DateTimeOriginal from Date and Time Created if not extracted already
    DateTimeOriginal = {
        TagID = 'Exif-DateTimeOriginal',
        Condition = function(self) return self.VALUE.DateTimeOriginal == nil end,
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        Desire = {
            [0] = 'DateTimeCreated',
            [1] = 'DateCreated',
            [2] = 'TimeCreated',
        },
        RawConv = function(_self, val)
            if perlTruthy(val[1]) and perlTruthy(val[2]) then return val end
            return nil
        end,
        ValueConv = function(_self, val)
            if perlTruthy(val[0]) and isMatch(val[0], [[ ]]) then return val[0] end
            return perlStr(val[1]) .. ' ' .. perlStr(val[2])
        end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
    },
    RedBalance = {
        TagID = 'Exif-RedBalance',
        Groups = { [2] = 'Camera' },
        Desire = {
            [0] = 'WB_RGGBLevels',
            [1] = 'WB_RGBGLevels',
            [2] = 'WB_RBGGLevels',
            [3] = 'WB_GRBGLevels',
            [4] = 'WB_GRGBLevels',
            [5] = 'WB_GBRGLevels',
            [6] = 'WB_RGBLevels',
            [7] = 'WB_GRBLevels',
            [8] = 'WB_RBLevels',
            [9] = 'WBRedLevel', -- red
            [10] = 'WBGreenLevel',
        },
        ValueConv = function(_self, val) return RedBlueBalance(0, val) end,
        PrintConv = function(self, val) return self.NumStr(perl.int(val * 1e6 + 0.5) * 1e-6) end,
    },
    BlueBalance = {
        TagID = 'Exif-BlueBalance',
        Groups = { [2] = 'Camera' },
        Desire = {
            [0] = 'WB_RGGBLevels',
            [1] = 'WB_RGBGLevels',
            [2] = 'WB_RBGGLevels',
            [3] = 'WB_GRBGLevels',
            [4] = 'WB_GRGBLevels',
            [5] = 'WB_GBRGLevels',
            [6] = 'WB_RGBLevels',
            [7] = 'WB_GRBLevels',
            [8] = 'WB_RBLevels',
            [9] = 'WBBlueLevel', -- blue
            [10] = 'WBGreenLevel',
        },
        ValueConv = function(_self, val) return RedBlueBalance(1, val) end,
        PrintConv = function(self, val) return self.NumStr(perl.int(val * 1e6 + 0.5) * 1e-6) end,
    },
    PreviewImageSize = {
        TagID = 'Exif-PreviewImageSize',
        Require = {
            [0] = 'PreviewImageWidth',
            [1] = 'PreviewImageHeight',
        },
        ValueConv = function(_self, val) return perlStr(val[0]) .. 'x' .. perlStr(val[1]) end,
    },
    SubSecDateTimeOriginal = {
        TagID = 'Exif-SubSecDateTimeOriginal',
        Description = 'Date/Time Original',
        Groups = { [2] = 'Time' },
        Writable = 1,
        Shift = 0, -- don't shift this tag
        Require = { [0] = 'EXIF:DateTimeOriginal' },
        Desire = {
            [1] = 'EXIF:SubSecTimeOriginal',
            [2] = 'EXIF:OffsetTimeOriginal',
        },
        WriteAlso = {
            ['EXIF:DateTimeOriginal'] = function(_self, val)
                if perlTruthy(val) then
                    local m = matches(val, [[^(\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2})]])
                    if m then return m end
                end
                return nil
            end,
            ['EXIF:SubSecTimeOriginal'] = function(_self, val)
                if perlTruthy(val) then
                    local m = matches(val, [[\.(\d+)]])
                    if m then return m end
                end
                return nil
            end,
            ['EXIF:OffsetTimeOriginal'] = function(_self, val)
                if perlTruthy(val) then
                    local m = matches(val, [[([-+]\d{2}:\d{2}|Z)$]])
                    if m then return m == "Z" and "+00:00" or m end
                end
                return nil
            end,
        },
        RawConv = function(_self, val) return subSecConv(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return require('lexiftool.Writer').InverseDateTime(self, val) end,
    },
    SubSecCreateDate = {
        TagID = 'Exif-SubSecCreateDate',
        Description = 'Create Date',
        Groups = { [2] = 'Time' },
        Writable = 1,
        Shift = 0, -- don't shift this tag
        Require = { [0] = 'EXIF:CreateDate' },
        Desire = {
            [1] = 'EXIF:SubSecTimeDigitized',
            [2] = 'EXIF:OffsetTimeDigitized',
        },
        WriteAlso = {
            ['EXIF:CreateDate'] = function(_self, val)
                if perlTruthy(val) then
                    local m = matches(val, [[^(\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2})]])
                    if m then return m end
                end
                return nil
            end,
            ['EXIF:SubSecTimeDigitized'] = function(_self, val)
                if perlTruthy(val) then
                    local m = matches(val, [[\.(\d+)]])
                    if m then return m end
                end
                return nil
            end,
            ['EXIF:OffsetTimeDigitized'] = function(_self, val)
                if perlTruthy(val) then
                    local m = matches(val, [[([-+]\d{2}:\d{2}|Z)$]])
                    if m then return m == "Z" and "+00:00" or m end
                end
                return nil
            end,
        },
        RawConv = function(_self, val) return subSecConv(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return require('lexiftool.Writer').InverseDateTime(self, val) end,
    },
    SubSecModifyDate = {
        TagID = 'Exif-SubSecModifyDate',
        Description = 'Modify Date',
        Groups = { [2] = 'Time' },
        Writable = 1,
        Shift = 0, -- don't shift this tag
        Require = { [0] = 'EXIF:ModifyDate' },
        Desire = {
            [1] = 'EXIF:SubSecTime',
            [2] = 'EXIF:OffsetTime',
        },
        WriteAlso = {
            ['EXIF:ModifyDate'] = function(_self, val)
                if perlTruthy(val) then
                    local m = matches(val, [[^(\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2})]])
                    if m then return m end
                end
                return nil
            end,
            ['EXIF:SubSecTime'] = function(_self, val) if perlTruthy(val) then local m = matches(val, [[\.(\d+)]]) if m then return m end end return nil end,
            ['EXIF:OffsetTime'] = function(_self, val)
                if perlTruthy(val) then
                    local m = matches(val, [[([-+]\d{2}:\d{2}|Z)$]])
                    if m then return m == "Z" and "+00:00" or m end
                end
                return nil
            end,
        },
        RawConv = function(_self, val) return subSecConv(val) end,
        PrintConv = function(self, val) return self:ConvertDateTime(val) end,
        PrintConvInv = function(self, val) return require('lexiftool.Writer').InverseDateTime(self, val) end,
    },
    LensID = {
        TagID = 'Exif-LensID',
        Groups = { [2] = 'Camera' },
        Require = { [0] = 'LensType' }, -- (upstream: bare `Require => 'LensType'`, index 0)
        Desire = {
            [1] = 'FocalLength',
            [2] = 'MaxAperture',
            [3] = 'MaxApertureValue',
            [4] = 'MinFocalLength',
            [5] = 'MaxFocalLength',
            [6] = 'LensModel',
            [7] = 'LensFocalRange',
            [8] = 'LensSpec',
            [9] = 'LensType2',
            [10] = 'LensType3',
            [11] = 'LensFocalLength', -- (for Pentax to check for converter)
            [12] = 'RFLensType',
        },
        Notes = [[
            attempt to identify the actual lens from all lenses with a given LensType.
            Applies only to LensType values with a lookup table.  May be configured
            by adding user-defined lenses
        ]],
        -- this LensID is only valid if the LensType has a PrintConv or is a model name
        RawConv = function(self, val)
            local printConv = self.TAG_INFO.LensType and self.TAG_INFO.LensType.PrintConv
            if type(printConv) == 'table' or (type(val[0]) == 'string' and matches(val[0], [[(mm|\d/F)]])) then
                return val
            end
            return nil
        end,
        -- upstream `ValueConv => '$val'`: a string conversion sees Perl's
        -- $val, which for a Composite tag is the FIRST Require value -- i.e.
        -- the plain LensType (what -n prints). The PrintConv below gets the
        -- whole Require/Desire list as its third argument, as upstream's own
        -- PrintConv sees @val.
        ValueConv = function(_self, val) return val[0] end,
        PrintConv = function(self, _v, val, prt)
            local pcv
            -- (upstream modifies its own copies of @val/@prt)
            local val_, prt0 = {}, prt[0]
            for k, v in pairs(val) do val_[k] = v end
            -- use LensType2 instead of LensType if available and valid (Sony E-mount lenses)
            -- (0x8000 or greater; 0 for several older/3rd-party E-mount lenses)
            if val[9] ~= nil and ((perl.int(val[9]) & 0x8000) ~= 0 or perl.num(val[9]) == 0) then
                val_[0] = val[9]
                prt0 = prt[9]
                -- Particularly GM lenses: often LensType2=0 but LensType3 is available and valid: use LensType3.
                if perl.num(val[9]) == 0 and (perl.int(val[10]) & 0x8000) ~= 0 then
                   val_[0] = val[10]
                   prt0 = prt[10]
                end
                pcv = self.TAG_INFO.LensType2 and self.TAG_INFO.LensType2.PrintConv
            end
            -- use Canon RFLensType if available
            if perlTruthy(val[12]) then
                val_[0] = val[12]
                prt0 = prt[12]
                pcv = self.TAG_INFO.RFLensType and self.TAG_INFO.RFLensType.PrintConv
            end
            local lens = PrintLensID(self, prt0, pcv, prt[8], val_[0], val_[1], val_[2], val_[3], val_[4],
                                     val_[5], val_[6], val_[7], val_[8], val_[9], val_[10], val_[11], val_[12])
            -- check for use of lens converter (Pentax K-3)
            if perlTruthy(val[11]) and perlTruthy(val[1]) and lens then
                local conv = perl.num(val[1]) / perl.num(val[11])
                if conv > 1.1 then lens = lens .. sprintf(' + %.1fx converter', conv) end
            end
            return lens
        end,
    },
    ['LensID-2'] = {
        TagID = 'Exif-LensID-2',
        Name = 'LensID',
        Groups = { [2] = 'Camera' },
        Desire = {
            [0] = 'LensModel',
            [1] = 'Lens',
            [2] = 'XMP-aux:LensID',
            [3] = 'Make',
        },
        Inhibit = { [4] = 'Composite:LensID' }, -- don't build this tag if
            -- the primary (LensType-based) LensID composite already
            -- produced a value
        RawConv = function(_self, val)
            if val[2] ~= nil and val[3] ~= nil then return nil end
            if val[0] ~= nil and matches(perlStr(val[0]), [[(mm|\d/F)]]) then
                return val
            end
            if val[1] ~= nil and matches(perlStr(val[1]), [[(mm|\d/F)]]) then
                return val
            end
            return nil
        end,
        ValueConv = function(_self, val)
            if val[0] ~= nil and matches(perlStr(val[0]), [[(mm|\d/F)]]) then return val[0] end
            return val[1]
        end,
        PrintConv = function(_self, val)
            local s = perlStr(val)
            -- upstream: `s/(\d)\/F/$1mm F/; s/mmF/mm F/; s/(\d) mm/${1}mm/; s/ - /-/`
            -- (PCRE2, since the `(\d)\/F` alternative isn't a Lua pattern)
            s = subst(s, [[(\d)\/F]], '$1mm F')
            s = subst(s, [[mmF]], 'mm F')
            s = subst(s, [[(\d) mm]], '${1}mm')
            s = subst(s, [[ - ]], '-')
            return s
        end,
    },
}

-- add our composite tags
ExifTool.AddCompositeTags('lexiftool.Exif', nil, Exif)

-- table for unknown IFD entries
-- (WRITE_PROC => \&WriteExif is wired in WriteExif.lua)
Exif.Unknown = {
    GROUPS = { [0] = 'EXIF', [1] = 'UnknownIFD', [2] = 'Image' },
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
}

-- Get class name of next IFD offset for HtmlDump output (upstream
-- Exif.pm NextOffsetName). et.OffsetNum is a running per-ExifTool-object
-- counter, mirroring upstream's `$$et{OffsetNum}`.
-- Inputs: 0) ExifTool object, 1) current class ID (optional)
-- Returns: 0) new IFD offset name, 1) new class ID including "Offset_" for
--          new offset, 2) new "Offset_" ID
local function NextOffsetName(et, id)
    et.OffsetNum = et.OffsetNum ~= nil and et.OffsetNum + 1 or 0
    local offName = 'o' .. et.OffsetNum
    local sid = 'Offset_' .. offName
    id = (id ~= nil and (id .. ' ') or '') .. sid
    return offName, id, sid
end

-- Generate a name for the tag with the specified ID (upstream Exif.pm TagName)
-- Inputs: 0) tag ID, 1) optional tagInfo ref
-- Returns: tag name string
local function TagName(tagID, tagInfo)
    local tagName = tagInfo and (' ' .. tagInfo.Name) or ''
    return sprintf('tag 0x%.4x%s', tagID, tagName)
end

-- Process an EXIF/TIFF directory (port of Exif::ProcessExif read subset).
-- Inputs: 0) ExifTool object, 1) dirInfo, 2) tag table ref
-- Returns: 1 on success
function Exif.ProcessExif(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dataPos = dirInfo.DataPos or 0
    local dataLen = dirInfo.DataLen
    local dirStart = dirInfo.DirStart or 0
    local dirLen = dirInfo.DirLen or (dataLen - dirStart)
    local dirName = dirInfo.DirName
    local base = dirInfo.Base or 0
    local firstBase = base
    local raf = dirInfo.RAF
    local validate = ExifTool.perlTruthy(et.OPTIONS.Validate)
    local success = 1
    local offsetInfo = {}
    local inMakerNotes = tagTablePtr.GROUPS and tagTablePtr.GROUPS[0] == 'MakerNotes'
    local isExif = (tagTablePtr == Exif.Main)
    -- warn for incorrect maker notes in CR3 files
    if dirName == 'MakerNotes' then
        if et.FileType == 'CR3' and dirInfo.Parent and dirInfo.Parent == 'ExifIFD' then
            et:Warn("MakerNotes shouldn't exist ExifIFD of CR3 image", 1)
        end
        if dirInfo.TagInfo and dirInfo.TagInfo.MakerNotes and
            perlTruthy(et.ExifByteOrder) and et.ExifByteOrder ~= et.GetByteOrder()
        then
            et:FoundTag('MakerNoteByteOrder', et.GetByteOrder())
        end
    end
    -- set flag to calculate image data hash if requested
    -- (rawget: the member, not the method of that name)
    local doHash
    if rawget(et, 'ImageDataHash') and ((et.FILE_TYPE == 'TIFF' and not perlTruthy(base) and not inMakerNotes) or
        (et.FILE_TYPE == 'RAF' and dirName == 'FujiIFD'))
    then
        doHash = 1
    end
    -- set encoding to assume for strings (Exif.pm:6313)
    local strEnc
    if tagTablePtr.GROUPS and tagTablePtr.GROUPS[0] == 'EXIF' then
        strEnc = et:Options('CharsetEXIF')
    end

    -- ignore non-standard EXIF while in strict MWG compatibility mode
    if (validate or ExifTool.MWGstrict()) and dirName == 'IFD0' and
        isExif and matches(et.FILE_TYPE, [[^(JPEG|TIFF|PSD)$]])
    then
        local path = et:MetadataPath()
        if matches(path, [[^(JPEG-APP1-IFD0|TIFF-IFD0|PSD-EXIFInfo-IFD0)$]]) then
            if not et.DOC_NUM then
                if et.HasExif then et:Warn('Duplicate EXIF at ' .. path) end
                et.HasExif = 1
            end
        else
            if ExifTool.MWGstrict() then
                et:Warn('Ignored non-standard EXIF at ' .. path)
                return 0
            else
                et:Warn('Non-standard EXIF at ' .. path, 1)
            end
        end
    end


    -- a more descriptive name for MakerNote sub-directories, used for the
    -- HtmlDump entry labels (upstream: `my $dir = $$dirInfo{Name}; $dir =
    -- $dirName unless $dir and $inMakerNotes and $dir !~ /^MakerNote/;`)
    local dir = dirInfo.Name
    if not (dir and inMakerNotes and not matches(dir, [[^MakerNote]])) then
        dir = dirName
    end

    -- scan for subsequent IFD's (upstream: Multi is set for IFD0/SubIFD)
    if (dirName == 'IFD0' or dirName == 'SubIFD') and dirInfo.Multi == nil then
        dirInfo.Multi = 1
    end

    local numEntries
    local dirSize
    local dirEnd
    if dirStart >= 0 and dirStart <= dataLen - 2 then
        -- make sure data is large enough
        numEntries = et.Get16u(dataPt, dirStart)
        dirSize = 2 + 12 * numEntries
        dirEnd = dirStart + dirSize
        if dirSize > dirLen then
            if ((tonumber(et.OPTIONS.Verbose) or 0) > 0 or validate) and not perlTruthy(dirInfo.SubIFD) then
                local short = dirSize - dirLen
                et.INDENT = subst(et.INDENT, [[..$]], '') -- keep indent the same
                et:Warn('Short directory size for ' .. dir .. ' (missing ' .. short .. ' bytes)')
                et.INDENT = et.INDENT .. '| '
            end
            if dirEnd > dataLen then dirSize = nil end -- read from file if necessary
        end
    end
    -- read IFD from file if necessary
    if not dirSize then
        success = 0
        if raf then
            local offset = dirStart + dataPos
            local buff
            -- upstream: $raf->Seek($offset + $base, 0) - without this the
            -- read below uses whatever position the RAF was last left at
            -- (only coincidentally correct when the IFD happens to start
            -- right where the previous read stopped, e.g. IFD0 at offset 8
            -- immediately after an 8-byte TIFF header)
            if raf:Seek(offset + base, 0) then
                local n, b = raf:Read(2)
                if n == 2 then
                    local len = 12 * et.Get16u(b, 0)
                    local n2, b2 = raf:Read(len + 4)
                    if n2 >= len then
                        buff = b .. (b2 or '')
                        dataPt = buff;      dirInfo.DataPt = dataPt
                        dataPos = offset;   dirInfo.DataPos = dataPos
                        dataLen = #buff;    dirInfo.DataLen = dataLen
                        dirStart = 0;       dirInfo.DirStart = dirStart
                        dirLen = #buff;     dirInfo.DirLen = dirLen
                        success = 1
                    end
                end
            end
        end
        if success ~= 0 then
            numEntries = et.Get16u(dataPt, dirStart)
        else
            et:Warn('Bad ' .. dir .. ' directory', inMakerNotes)
            if not (inMakerNotes and dirLen >= 14 and dirStart >= 0 and
                    dirStart + dirLen <= length(dataPt)) then return 0 end
            dirSize = dirLen
            numEntries = perl.int((dirSize - 2) / 12) -- read what we can
            -- (the count is written into the caller's scalar; a string
            --  buffer becomes a carray for that -- api.md §4)
            if type(dataPt) == 'string' then
                dataPt = require('carray').new('char'):append(dataPt)
                dirInfo.DataPt = dataPt
            end
            et.Set16u(dataPt, dirStart, numEntries)
        end
        dirSize = 2 + 12 * numEntries
        dirEnd = dirStart + dirSize
    end
    local bytesFromEnd = dataLen - dirEnd
    if bytesFromEnd < 4 then
        if not (bytesFromEnd == 2 or bytesFromEnd == 0) then
            et:Warn('Illegal ' .. dir .. ' directory size (' .. numEntries .. ' entries)')
            return 0
        end
    end
    -- print verbose directory information (upstream Exif.pm ProcessExif)
    if et.OPTIONS.Verbose and et.OPTIONS.Verbose > 0 then
        et:VerboseDir(dirName, numEntries, nil, et.GetByteOrder())
    end

    -- fix base offset for maker notes if necessary
    local makerAddr
    if dirInfo.MakerNoteAddr ~= nil then
        makerAddr = dirInfo.MakerNoteAddr
        dirInfo.MakerNoteAddr = nil
        if MakerNotes.FixBase(et, dirInfo) ~= 0 then
            base = dirInfo.Base or 0
            dataPos = dirInfo.DataPos or 0
        end
    end

    -- HtmlDump: directory header (entry count + Next IFD pointer), upstream
    -- Exif.pm ProcessExif's `if ($htmlDump) {...}` block right before the
    -- per-entry loop
    local offName, nextOffName
    if et.HTML_DUMP then
        offName = dirInfo.OffsetName
        local longName = (dir == 'MakerNotes') and (dirInfo.Name or dir) or dir
        if makerAddr ~= nil then
            local hdrLen = dirStart + dataPos + base - makerAddr
            if hdrLen > 0 then
                et:HDump(makerAddr, hdrLen, 'MakerNotes header', longName)
            end
        end
        if not dirInfo.NoDumpEntryCount then
            et:HDump(dirStart + dataPos + base, 2, longName .. ' entries',
                'Entry count: ' .. numEntries, nil, offName)
        end
        local tip
        local id = offName
        if bytesFromEnd >= 4 then
            local prefix, num = dir:match('^(.-)(%d+)$')
            local nxt = prefix and (prefix .. (tonumber(num) + 1)) or 'Next IFD'
            local off = et.Get32u(dataPt, dirEnd)
            tip = sprintf('%s offset: 0x%.4x', nxt, off)
            if off ~= 0 then
                nextOffName, id = NextOffsetName(et, offName)
            end
        end
        et:HDump(dirEnd + dataPos + base, 4, 'Next IFD', tip, 0, id)
    end

    -- loop through all entries in an EXIF directory (IFD)
    local mapFmt = tagTablePtr.VARS and tagTablePtr.VARS.MAP_FORMAT
    local valEnd
    local valPos = {}
    local warnCount = 0
    local lastID = -1
    local offList, offHash
    for index = 0, numEntries - 1 do
        if warnCount > 10 then
            if et:Warn('Too many warnings -- ' .. dir .. ' parsing aborted', 2) then return 0 end
        end
        local entry = dirStart + 2 + 12 * index
        local tagID = et.Get16u(dataPt, entry)
        local format = et.Get16u(dataPt, entry + 2)
        local count = et.Get32u(dataPt, entry + 4)
        -- (Apple uses the BigTIFF format code 16 in the maker notes of their ProRaw DNG files)
        if (format < 1 or format > 13) and format ~= 129 and not (format == 16 and et.Make == 'Apple' and inMakerNotes) then
            if mapFmt and mapFmt[format] then
                format = mapFmt[format]
            else
                et:HDump(entry + dataPos + base, 12, '[invalid IFD entry]',
                         'Bad format type: ' .. format, 1, offName)
                -- warn unless the IFD was just padded with zeros
                if format ~= 0 or validate then
                    et:Warn('Bad format (' .. format .. ') for ' .. dir .. ' entry ' .. index, inMakerNotes)
                    warnCount = warnCount + 1
                end
                -- assume corrupted IFD if this is our first entry (except Sony ILCE which have an empty first entry)
                if index ~= 0 or isMatch(et.Model, [[^ILCE]]) then goto continue end
                -- $et->Warn(sprintf('Format code 0x%x encountered -- Possibly corrupted IFD'));
                return 0
            end
        end
        local formatStr = Exif.formatName[format] -- get name of this format
        local valueDataPt = dataPt
        local valueDataPos = dataPos
        local valueDataLen = dataLen
        local valuePtr = entry + 8 -- pointer to value within dataPt
        -- hack to patch incorrect count in Kodak SubIFD3 tags
        local countFormStr  -- (upstream's $origFormStr from this hack)
        if count < 2 and type(tagTablePtr[tagID]) == 'table' and tagTablePtr[tagID].FixCount then
            if not offList then
                offList, offHash = require('lexiftool.WriteExif').GetOffList(dataPt, dirStart, dataPos,
                                                                           numEntries, tagTablePtr)
            end
            local i = offHash[et.Get32u(dataPt, valuePtr)]
            if i ~= nil and i < #offList - 1 then
                local oldCount = count
                count = perl.int((offList[i + 2] - offList[i + 1]) / Exif.formatSize[format])
                if oldCount ~= count then countFormStr = Exif.formatName[format] .. '[' .. oldCount .. ']' end
            end
        end
        local size = count * (Exif.formatSize[format] or 1)
        local readSize = size
        local bad = false
        if size > 4 then
            local sizeInfo = size > 0x7fffffff and et:GetTagInfo(tagTablePtr, tagID)
            if size > 0x7fffffff and (not sizeInfo or not sizeInfo.ReadFromRAF) then
                et:Warn(sprintf('Invalid size (%u) for %s %s', size, dir, TagName(tagID, sizeInfo)), inMakerNotes)
                warnCount = warnCount + 1
                goto continue
            end
            valuePtr = et.Get32u(dataPt, valuePtr)
            if validate and not inMakerNotes then
                -- (upstream already has the full tagInfo here; this port
                --  resolves it further down, after the value position is
                --  known, so the name for these messages comes from a
                --  value-less GetTagInfo)
                local tagName = TagName(tagID, et:GetTagInfo(tagTablePtr, tagID))
                if valuePtr & 0x01 ~= 0 then et:Warn('Odd offset for ' .. dir .. ' ' .. tagName, 1) end
                if valuePtr < 8 or (valuePtr + size > length(dataPt) and
                                    valuePtr + size > (tonumber(et.VALUE.FileSize) or 0))
                then
                    et:Warn('Invalid offset for ' .. dir .. ' ' .. tagName)
                    warnCount = warnCount + 1
                    goto continue
                end
                if valuePtr + size > dirStart + dataPos and valuePtr < dirEnd + dataPos + 4 then
                    et:Warn('Value for ' .. dir .. ' ' .. tagName .. ' overlaps IFD')
                end
                for _, vp in ipairs(valPos) do
                    if not (vp[1] >= valuePtr + size or vp[1] + vp[2] <= valuePtr) then
                        et:Warn('Value for ' .. dir .. ' ' .. tagName .. ' overlaps ' .. vp[3])
                    end
                end
                valPos[#valPos + 1] = { valuePtr, size, tagName }
            end
            -- fix valuePtr if necessary
            if dirInfo.FixOffsets then
                local wFlag = nil
                valEnd = perlTruthy(valEnd) and valEnd or dataPos + dirEnd + 4
                --### eval FixOffsets ($valuePtr, $valEnd, $size, $tagID, $wFlag)
                -- (upstream evals a code string that modifies $valuePtr/$valEnd
                --  in place; the port's FixOffsets returns both)
                valuePtr, valEnd = dirInfo.FixOffsets(valuePtr, valEnd, size, tagID, wFlag)
            end
            -- upstream: offset shouldn't point into the TIFF header, and
            -- the value shouldn't overlap our own directory -- either one
            -- marks this entry "suspect", warned about below only if
            -- nothing else about this entry already produced a warning
            local suspect = (valuePtr < 8 and not dirInfo.ZeroOffsetOK) and warnCount or nil
            -- convert offset to pointer in dataPt
            local tagEntry = tagTablePtr[tagID]
            if ExifTool.perlTruthy(dirInfo.EntryBased) or
               (type(tagEntry) == 'table' and ExifTool.perlTruthy(tagEntry.EntryBased))
            then
                -- entry-based offsets are relative to the start of this very
                -- IFD entry (FixBase has already moved Base to the first one)
                valuePtr = valuePtr + entry
            else
                valuePtr = valuePtr - dataPos
            end
            if suspect == nil and valuePtr < dirEnd and valuePtr + size > dirStart then
                suspect = warnCount
            end
            -- load value from file if necessary
            if valuePtr < 0 or valuePtr + size > dataLen then
                local buff
                if raf then
                    -- (upstream's $tagInfo of this point: the value-less lookup)
                    local tagInfo0 = et:GetTagInfo(tagTablePtr, tagID)
                    -- avoid loading large binary data unless necessary
                    while size > Exif.BINARY_DATA_LIMIT() do -- luacheck: ignore 512 (upstream: while with `last`)
                        if tagInfo0 then
                            -- make large unknown blocks binary data
                            if tagInfo0.Unknown then tagInfo0.Binary = 1 end
                            if not tagInfo0.Binary then break end      -- must read non-binary data
                            if tagInfo0.SubDirectory then break end
                            local lcTag = lc(tagInfo0.Name)
                            if perlTruthy(et.OPTIONS.Binary) and
                                not (et.EXCL_TAG_LOOKUP and et.EXCL_TAG_LOOKUP[lcTag])
                            then
                                -- read binary data if specified unless tagsFromFile won't use it
                                if not (et.TAGS_FROM_FILE and tagInfo0.Protected) then break end
                            end
                            -- must read if tag is specified by name
                            if et.REQ_TAG_LOOKUP and et.REQ_TAG_LOOKUP[lcTag] then break end
                        else
                            -- must read value if needed for a condition
                            if tagInfo0 ~= nil then break end
                        end
                        -- (note: changing the value without changing $size will cause
                        -- a warning in the verbose output, but we need to maintain the
                        -- proper size for the htmlDump, so we can't change this)
                        buff = 'Binary data ' .. size .. ' bytes'
                        readSize = #buff
                        break
                    end
                    -- read from file if necessary
                    if buff == nil then
                        local wrn, truncOK
                        local readFromRAF = tagInfo0 and tagInfo0.ReadFromRAF
                        if not raf:Seek(base + valuePtr + dataPos, 0) then
                            wrn = 'Invalid offset for ' .. dir .. ' entry ' .. index
                        elseif readFromRAF and size > Exif.BINARY_DATA_LIMIT() and
                            not (et.REQ_TAG_LOOKUP and et.REQ_TAG_LOOKUP[lc(tagInfo0.Name)])
                        then
                            buff = tagInfo0.Name .. ' data ' .. size .. ' bytes'
                            readSize = #buff
                        else
                            local n
                            n, buff = raf:Read(size)
                            if n ~= size then
                                wrn = sprintf('Error reading value for ' .. dir .. ' entry ' .. index .. ', ID 0x%.4x', tagID)
                                if tagInfo0 and not tagInfo0.Unknown then
                                    wrn = wrn .. ' ' .. tagInfo0.Name
                                    truncOK = tagInfo0.TruncateOK
                                end
                            elseif readFromRAF then
                                -- seek back to the start of the value
                                raf:Seek(base + valuePtr + dataPos, 0)
                            end
                        end
                        if wrn then
                            et:Warn(wrn, inMakerNotes or truncOK)
                            if not (inMakerNotes or et.HTML_DUMP or truncOK) then return 0 end
                            warnCount = warnCount + 1
                            if buff == nil then buff = '' end
                            readSize = #buff
                            if not truncOK then bad = true end
                        end
                    end
                    valueDataLen = #buff
                    valueDataPt = buff
                    valueDataPos = valuePtr + dataPos
                    valuePtr = 0
                else
                    local tagStr, tmpInfo, leicaTrailer
                    local tagInfo0 = et:GetTagInfo(tagTablePtr, tagID)
                    if tagInfo0 then
                        tagStr = tagInfo0.Name
                        leicaTrailer = tagInfo0.LeicaTrailer
                    elseif tagInfo0 ~= nil then
                        tmpInfo = et:GetTagInfo(tagTablePtr, tagID, '', formatStr, count)
                        if tmpInfo then
                            tagStr = tmpInfo.Name
                            leicaTrailer = tmpInfo.LeicaTrailer
                        end
                    end
                    if tagInfo0 and tagInfo0.ChangeBase then
                        -- adjust base offset for this tag only
                        --### eval ChangeBase ($dirStart,$dataPos)
                        local newBase = tagInfo0.ChangeBase(dirStart, dataPos)
                        valuePtr = valuePtr + newBase
                    end
                    if not tagStr then tagStr = sprintf('tag 0x%.4x', tagID) end
                    -- allow PreviewImage to run outside EXIF data
                    if tagStr == 'PreviewImage' and et.RAF then
                        local pos = et.RAF:Tell()
                        buff = et:ExtractBinary(base + valuePtr + dataPos, size, 'PreviewImage')
                        et.RAF:Seek(pos, 0)
                        valueDataPt = buff
                        valueDataPos = valuePtr + dataPos
                        valueDataLen = size
                        valuePtr = 0
                    elseif leicaTrailer and et.RAF then
                        if (tonumber(et.OPTIONS.Verbose) or 0) > 0 then
                            et:VPrint(0, (et.INDENT or '') .. index .. ') ' .. tagStr .. ' --> (outside APP1 segment)\n')
                        end
                        if perlTruthy(et:Options('FastScan')) then
                            et:Warn('Ignored Leica MakerNote trailer')
                        else
                            et.LeicaTrailer = {
                                TagInfo = tagInfo0 or tmpInfo,
                                Offset  = base + valuePtr + dataPos,
                                Size    = size,
                                Fixup   = require('lexiftool.Fixup').new(),
                            }
                        end
                    else
                        et:Warn('Bad offset for ' .. dir .. ' ' .. tagStr, inMakerNotes)
                        warnCount = warnCount + 1
                    end
                    if buff == nil then
                        -- (upstream assigns a plain '' -- not a scalar ref -- so
                        --  the verbose output shows neither a value nor a dump)
                        valueDataPt = false
                        valueDataPos = valuePtr + dataPos
                        valueDataLen = 0
                        valuePtr = 0
                        bad = true
                    end
                end
            end
            -- warn about suspect offsets if they didn't already cause
            -- another warning
            if suspect ~= nil and suspect == warnCount then
                local earlyInfo = et:GetTagInfo(tagTablePtr, tagID)
                local tagStr = earlyInfo and earlyInfo.Name or sprintf('tag 0x%.4x', tagID)
                if et:Warn('Suspicious ' .. dir .. ' offset for ' .. tagStr, inMakerNotes) then
                    warnCount = warnCount + 1
                    local verboseOpt = et.OPTIONS.Verbose
                    if verboseOpt == nil or verboseOpt == false or verboseOpt == 0 then
                        goto continue
                    end
                end
            end
        end
        -- fetch a short byte prefix at the resolved value position so a
        -- Condition closure that inspects the raw bytes ('$$valPt' in the
        -- Perl original, e.g. Nikon's version-prefixed SubDirectory
        -- dispatch) can be evaluated. Upstream does a first GetTagInfo call
        -- without a value and only retries with the actual bytes if a
        -- Condition needed them; collapsed into one call here since
        -- resolving the value position above never itself depends on which
        -- candidate tagInfo wins (none of the ported conditional entries
        -- override Format/FixedSize).
        local tmpVal
        if type(valueDataPt) == 'string' then
            local n = readSize < 128 and readSize or 128
            tmpVal = substr(valueDataPt, valuePtr, n) or ''
        end
        local tagInfo
        if bad then
            -- (upstream: a Condition that needs the value is not evaluated
            --  for a bad pointer entry -- `undef $tagInfo if $bad`)
            tagInfo = et:GetTagInfo(tagTablePtr, tagID)
            if tagInfo == false then tagInfo = nil end
        else
            tagInfo = et:GetTagInfo(tagTablePtr, tagID, tmpVal, formatStr, count)
        end
        -- make sure we are handling the 'ifd' format properly
        if (format == 13 or format == 18) and (not tagInfo or not tagInfo.SubIFD) then
            local str = sprintf('%s tag 0x%.4x IFD format not handled', dirName, tagID)
            et:Warn(str, inMakerNotes)
        end
        if validate and not inMakerNotes then require('lexiftool.Validate').ValidateExif(
            et, tagTablePtr, tagID, tagInfo, lastID, dir, count, formatStr) end
        -- upstream: the out-of-sequence/duplicate-tag check (and the
        -- $lastID update feeding it) lives entirely inside the verbose
        -- "else" branch of ProcessExif's per-entry block (the "if
        -- ($htmlDump) {...} else {...}" split), i.e. it only runs -- and
        -- only ever warns -- under -v; a non-verbose run never sees it.
        -- (upstream Exif.pm:6335 `$verbose = -2 if $validate and not $verbose`
        --  mixes Validate into $verbose, so -validate reaches the same block)
        if (et.OPTIONS.Verbose and et.OPTIONS.Verbose > 0) or validate then
            if tagID <= lastID and not inMakerNotes then
                local str = tagInfo and (' ' .. tagInfo.Name) or ''
                if tagID == lastID then
                    et:Warn(sprintf('Duplicate tag 0x%.4x%s in %s', tagID, str, dirName))
                else
                    et:Warn(sprintf('Tag ID 0x%.4x%s out of sequence in %s', tagID, str, dirName))
                end
            end
            lastID = tagID
        end
        -- upstream: `if (defined $tagInfo) {...} else { next unless
        -- $verbose; }` -- an unknown tag (no tagInfo) is skipped entirely
        -- under a plain read, but under -v *or* -htmlDump ($verbose is
        -- forced to -1 when $htmlDump is set, Exif.pm:6335) it still falls
        -- through so VerboseInfo/the html dump row gets built for it
        -- treat single unknown byte as int8u
        if format == 7 and count == 1 then formatStr = 'int8u' end

        local readFormat, subdir, wrongFormat
        if tagInfo then
            readFormat = tagInfo.Format
            subdir = tagInfo.SubDirectory
            -- unless otherwise specified, all SubDirectory data except EXIF
            -- SubIFD offsets should be unformatted
            if subdir and not tagInfo.SubIFD and not readFormat then readFormat = 'undef' end
            -- override EXIF format if specified
            if readFormat then
                formatStr = readFormat
            end
        elseif not (et.HTML_DUMP or (et.OPTIONS.Verbose and et.OPTIONS.Verbose > 0) or validate) then
            goto continue
        end
        -- if the tag table overrode the format, adjust the format number/count
        -- (e.g. IPTC-NAA is written as int32u but read as undef)
        local origFormStr = countFormStr
        local readFormatName = readFormat
        if readFormatName then
            local newNum = Exif.formatNumber[readFormatName]
            if newNum and newNum ~= format then
                origFormStr = Exif.formatName[format] .. '[' .. count .. ']'
                format = newNum
                if tagInfo.FixedSize then
                    size = tagInfo.FixedSize
                    readSize = tagInfo.FixedSize
                end
                -- adjust number of items for new format size
                count = math.floor(size / (Exif.formatSize[format] or 1))
            end
        end
        if tagInfo then
            -- verify that offset-type values are integral
            if (tagInfo.IsOffset or tagInfo.SubIFD) and not Exif.intFormat[formatStr] then
                et:Warn(sprintf('Wrong format (%s) for %s 0x%.4x %s',
                    formatStr, dir, tagID, tagInfo.Name))
                if validate then
                    if not et.WrongFormat then et.WrongFormat = {} end
                    et.WrongFormat[dir .. ':' .. tagInfo.Name] = 1
                    offsetInfo[tagID] = { tagInfo, '' }
                end
                if not (et.HTML_DUMP or (et.OPTIONS.Verbose and et.OPTIONS.Verbose > 0) or validate) then
                    goto continue
                end
                wrongFormat = 1
            end
        end

        local val
        local rational
        if not bad then
            -- limit maximum length of data to reformat
            -- (avoids long delays when processing some corrupted files)
            local warned
            if count > 100000 and not isMatch(formatStr, [[^(undef|string|binary)$]]) then
                local tagName = tagInfo and tagInfo.Name or sprintf('tag 0x%.4x', tagID)
                -- (count of 196608 is typical for ColorMap)
                if tagName ~= 'TransferFunction' or count ~= 196608 then
                    local minor = count > 2000000 and 0 or 2
                    if perlTruthy(et:Warn('Ignoring ' .. dirName .. ' ' .. tagName .. ' with excessive count', minor)) then
                        if not perlTruthy(et.OPTIONS.HtmlDump) then goto continue end
                        warned = 1
                    end
                end
            end
            if count > 500 and not isMatch(formatStr, [[^(undef|string|binary)$]]) and
                (not tagInfo or tagInfo.LongBinary or warned) and not perlTruthy(et.OPTIONS.IgnoreMinorErrors)
            then
                if not warned then et:Warn('Not decoding some large array(s). Ignore minor errors to decode', 2) end
                if et.TAGS_FROM_FILE then goto continue end   -- don't generate bogus value when copying tags
                val = '(large array of ' .. count .. ' ' .. formatStr .. ' values)'
            else
                local ratPt = { rat = nil }
                -- convert according to specified format
                val = et.ReadValue(valueDataPt, valuePtr, formatStr, count, readSize, ratPt)
                rational = ratPt.rat
                -- re-code if necessary (Exif.pm:6785)
                if val ~= nil then
                    if formatStr == 'utf8' then
                        val = et:Decode(val, 'UTF8')
                    elseif ExifTool.perlTruthy(strEnc) and formatStr == 'string' then
                        val = et:Decode(val, strEnc)
                    end
                end
            end
        end

        -- print verbose tag information (upstream Exif.pm ProcessExif's
        -- per-entry VerboseInfo call, before the SubDirectory handling) --
        -- or, under -htmlDump, build the per-entry dump row instead (the
        -- two are mutually exclusive branches of the same upstream `if
        -- ($verbose) {...}` block, since htmlDump mode never also sets
        -- Verbose)
        local subOffName
        if et.HTML_DUMP then
            local tval = val
            if rational ~= nil then tval = perlStr(tval) .. ' (' .. rational .. ')' end
            local tagName
            if tagInfo then
                tagName = tagInfo.Name
            elseif tagID == 0x927c and dirName == 'ExifIFD' then
                tagName = 'MakerNotes'
            else
                tagName = sprintf('Tag 0x%.4x', tagID)
            end
            local dname = sprintf('%s-%.2d', dir, index)
            if size < 0 then size = count * (Exif.formatSize[format] or 1) end
            local fstr = string.format('%s[%d]', Exif.formatName[format], count)
            if origFormStr and origFormStr ~= fstr then fstr = origFormStr .. ' read as ' .. fstr end
            if wrongFormat then fstr = fstr .. ' <-- WRONG' end
            local tip = sprintf('Tag ID: 0x%.4x\nFormat: %s\nSize: %d bytes\n', tagID, fstr, size)
            local colName
            if size > 4 then
                local offPt = et.Get32u(dataPt, entry + 8)
                local actPt = valuePtr + valueDataPos + base - (et.EXIF_POS or 0) + (et.BASE_FUDGE or et.BASE or 0)
                tip = tip .. sprintf('Value offset: 0x%.4x\n', offPt)
                local style = (bad or tval == nil) and 'V' or 'H'
                if actPt ~= offPt then
                    tip = tip .. sprintf('Actual offset: 0x%.4x\n', actPt)
                    local sign = actPt < offPt and '-' or ''
                    tip = tip .. sprintf('Offset base: %s0x%.4x\n', sign, math.abs(actPt - offPt))
                    if style == 'H' then style = 'F' end
                end
                if et.EXIF_POS and et.EXIF_POS ~= 0 and not et.BASE_FUDGE then
                    tip = tip .. sprintf('File offset:   0x%.4x\n', actPt + et.EXIF_POS)
                end
                colName = string.format('<span class=%s>%s</span>', style, tagName)
                if offPt & 0x01 ~= 0 then colName = colName .. ' <span class=V>(odd)</span>' end
            else
                colName = tagName
            end
            if wrongFormat then colName = colName .. ' <span class=V>(err)</span>' end
            if tagID <= lastID and not inMakerNotes then
                colName = colName .. ' <span class=V>(seq)</span>'
            end
            lastID = tagID
            if tval == nil then
                tval = '<bad size/offset>'
            else
                tval = perlStr(tval)
                if #tval > 32 then tval = substr(tval, 0, 28) .. '[...]' end
                if matches(formatStr, [[^(string|undef|binary)]]) then
                    -- translate non-printable characters
                    tval = (tval:gsub('[%z\1-\31\127-\255]', '.'))
                elseif tagInfo and matches(tval, [[^[+-]?\d+$]]) then
                    if tagInfo.IsOffset or tagInfo.SubIFD then
                        local nval = tonumber(val)
                        tval = sprintf('0x%.4x', nval)
                        local actPt2 = nval + base - (et.EXIF_POS or 0) + (et.BASE_FUDGE or et.BASE or 0)
                        if actPt2 ~= nval then
                            local sign2 = actPt2 < nval and '-' or ''
                            tval = tval .. sprintf('\nActual offset: 0x%.4x', actPt2)
                            tval = tval .. sprintf('\nOffset base: %s0x%.4x', sign2, math.abs(actPt2 - nval))
                        end
                        if et.EXIF_POS and et.EXIF_POS ~= 0 and not et.BASE_FUDGE then
                            tip = tip .. sprintf('File offset:   0x%.4x\n', actPt2 + et.EXIF_POS)
                        end
                    elseif tagInfo.PrintHex then
                        tval = sprintf('0x%x', tonumber(val))
                    end
                end
            end
            tip = tip .. 'Value: ' .. tval
            local id = offName
            local sid
            if tagInfo and tagInfo.SubIFD then
                subOffName, id, sid = NextOffsetName(et, offName)
            end
            et:HDump(entry + dataPos + base, 12, dname .. ' ' .. colName, tip, 1, id)
            -- upstream: `next if $valueDataLen < 0;  # don't process bad pointer entry`
            if valueDataLen < 0 then goto continue end
            if size > 4 then
                local exifDumpPos = valuePtr + valueDataPos + base
                local flag = 0
                if subdir then
                    if tagInfo.MakerNotes then
                        flag = 0x04
                    elseif tagInfo.NestedHtmlDump then
                        flag = tagInfo.NestedHtmlDump == 2 and 0x10 or 0x04
                    end
                end
                et:HDump(exifDumpPos, size, tagName .. ' value', 'SAME', flag, sid)
                if subdir and tagInfo.MakerNotes and tagInfo.NotIFD then
                    et:HDump(exifDumpPos, size, tagName .. ' value', nil, nil, dirInfo.OffsetName)
                end
            end
        elseif et.OPTIONS.Verbose and et.OPTIONS.Verbose > 0 then
            local tval = val
            if rational ~= nil then tval = perlStr(tval) .. ' (' .. rational .. ')' end
            local fstr = Exif.formatName[format]
            if origFormStr then fstr = origFormStr .. ' read as ' .. fstr end
            et:VerboseInfo(tagID, tagInfo, {
                Table   = tagTablePtr,
                Index   = index,
                Value   = tval,
                DataPt  = valueDataPt,
                DataPos = valueDataPos + base,
                Size    = size,
                Start   = valuePtr,
                Format  = fstr,
                Count   = count,
            })
        end
        -- upstream: `next if not $tagInfo or $wrongFormat;` (end of the
        -- `if ($verbose) {...}` block) -- an unknown tag only got this far
        -- (past the earlier `next unless $verbose` gate) to be dumped/
        -- verbose-printed; it was never meant to reach the SubDirectory/
        -- offset-conversion code below, which assumes tagInfo is defined
        if not tagInfo or wrongFormat then goto continue end
        if val == nil then goto continue end

        -- handle SubDirectory tag types
        if subdir then
            -- don't process empty subdirectories
            if not perlTruthy(size) then
                if not (tagInfo.MakerNotes or inMakerNotes) then
                    et:Warn('Empty ' .. tagInfo.Name .. ' data', 1)
                end
                goto continue
            end
            local values, newTagTable, newByteOrder, invalid = { }
            local dirNum
            local tagStr = tagInfo.Name
            local verbose = tonumber(et.OPTIONS.Verbose) or 0
            if subdir.MaxSubdirs then
                values = split(' ', val)
                -- limit the number of subdirectories we parse
                local over = #values - subdir.MaxSubdirs
                if over > 0 then
                    et:Warn('Ignoring ' .. over .. ' ' .. tagStr .. ' directories')
                    for _ = 1, over do table.remove(values) end
                end
                val = table.remove(values, 1)
            end
            if subdir.TagTable then
                newTagTable = et:GetTagTable(subdir.TagTable)
                if not newTagTable then
                    perl.warn('Unknown tag table ' .. subdir.TagTable)
                    goto continue
                end
            else
                newTagTable = tagTablePtr    -- use existing table
            end
            -- loop through all sub-directories specified by this tag
            dirNum = 0
            while true do
                local subdirBase = base
                local subdirDataPt = valueDataPt
                local subdirDataPos = valueDataPos
                local subdirDataLen = valueDataLen
                local subdirStart = valuePtr
                if subdir.Start ~= nil then
                    -- set local $valuePtr relative to file $base for eval
                    local valuePtr_ = subdirStart + subdirDataPos
                    --#### eval Start ($valuePtr, $val)
                    local newStart = subdir.Start(et, val, valuePtr_)
                    if not ExifTool.IsInt(newStart) then
                        et:Warn('Bad value for ' .. tagStr)
                        break
                    end
                    -- convert back to relative to $subdirDataPt
                    newStart = perl.num(newStart) - subdirDataPos
                    -- adjust directory size if necessary
                    if not (tagInfo.SubIFD or subdir.BadOffset) then
                        size = size - (newStart - subdirStart)
                    end
                    subdirStart = newStart
                end
                -- this is a pain, but some maker notes are always a specific
                -- byte order, regardless of the byte order of the file
                local oldByteOrder = ExifTool.GetByteOrder()
                newByteOrder = subdir.ByteOrder
                if perlTruthy(newByteOrder) then
                    if isMatch(newByteOrder, '(?i)^Little') then
                        newByteOrder = 'II'
                    elseif isMatch(newByteOrder, '(?i)^Big') then
                        newByteOrder = 'MM'
                    elseif subdir.OffsetPt then
                        newByteOrder = nil
                        perl.warn("Can't have variable byte ordering for SubDirectories using OffsetPt")
                        break
                    elseif subdirStart + 2 <= subdirDataLen then
                        -- attempt to determine the byte ordering by checking
                        -- the number of directory entries.  This is an int16u
                        -- that should be a reasonable value.
                        local num = ExifTool.Get16u(subdirDataPt, subdirStart)
                        if num & 0xff00 ~= 0 and (num>>8) > (num&0xff) then
                            -- This looks wrong, we shouldn't have this many entries
                            local otherOrder = { II='MM', MM='II' }
                            newByteOrder = otherOrder[oldByteOrder]
                        else
                            newByteOrder = oldByteOrder
                        end
                    end
                else
                    newByteOrder = oldByteOrder
                end
                -- set base offset if necessary
                if subdir.Base then
                    -- calculate subdirectory start relative to $base for eval
                    local start = subdirStart + subdirDataPos
                    --#### eval Base ($start,$base)
                    subdirBase = perl.num(subdir.Base(et, val, start, base)) + base
                end
                -- add offset to the start of the directory if necessary
                if subdir.OffsetPt then
                    --#### eval OffsetPt ($valuePtr)
                    local pos = perl.num(subdir.OffsetPt(et, val, valuePtr))
                    if pos + 4 > subdirDataLen then
                        et:Warn('Bad ' .. tagStr .. ' OffsetPt')
                        break
                    end
                    ExifTool.SetByteOrder(newByteOrder)
                    subdirStart = subdirStart + ExifTool.Get32u(subdirDataPt, pos)
                    ExifTool.SetByteOrder(oldByteOrder)
                end
                if subdirStart < 0 or subdirStart + 2 > subdirDataLen then
                    -- convert $subdirStart back to a file offset
                    if raf then
                        -- reset SubDirectory buffer (we will load it later)
                        local buff = ''
                        subdirDataPt = buff
                        subdirDataLen = length(buff)
                        size = subdirDataLen
                    else
                        local msg = 'Bad ' .. tagStr .. ' SubDirectory start'
                        if verbose > 0 then
                            if subdirStart < 0 then
                                msg = msg .. ' (directory start ' .. subdirStart .. ' is before EXIF start)'
                            else
                                local end_ = subdirStart + size
                                msg = msg .. ' (directory end is ' .. end_ .. ' but EXIF size is only ' .. subdirDataLen .. ')'
                            end
                        end
                        et:Warn(msg, inMakerNotes)
                        break
                    end
                end

                -- must update subdirDataPos if $base changes for this subdirectory
                subdirDataPos = subdirDataPos + (base - subdirBase)

                -- build information hash for new directory
                local subdirInfo = {
                    Name       = tagStr,
                    Base       = subdirBase,
                    DataPt     = subdirDataPt,
                    DataPos    = subdirDataPos,
                    DataLen    = subdirDataLen,
                    DirStart   = subdirStart,
                    DirLen     = size,
                    RAF        = raf,
                    Parent     = dirName,
                    DirName    = subdir.DirName,
                    FixBase    = subdir.FixBase,
                    FixOffsets = subdir.FixOffsets,
                    EntryBased = subdir.EntryBased,
                    TagInfo    = tagInfo,
                    SubIFD     = tagInfo.SubIFD,
                    Subdir     = subdir,
                    OffsetName = subOffName,
                }
                -- (remember: some cameras incorrectly write maker notes in IFD0)
                if tagInfo.MakerNotes then
                    -- don't parse makernotes if FastScan > 1
                    local fast = et:Options('FastScan')
                    if fast and fast > 1 then break end
                    subdirInfo.MakerNoteAddr = valuePtr + valueDataPos + base
                    if subdir.Base ~= nil then subdirInfo.NoFixBase = 1 end
                end
                -- set directory IFD name from group name of family 1 if it exists,
                -- unless the tag is writable as a block in which case group 1 may
                -- have been set automatically
                if tagInfo.Groups and not perlTruthy(tagInfo.Writable) then
                    subdirInfo.DirName = tagInfo.Groups[1]
                    -- number multiple subdirectories
                    if dirNum ~= 0 then subdirInfo.DirName = subst(subdirInfo.DirName, [[\d*$]], perlStr(dirNum)) end
                end
                ExifTool.SetByteOrder(newByteOrder)    -- set byte order for this subdir
                -- validate the subdirectory if necessary
                local dirData = subdirDataPt    -- set data pointer to be used in eval
                --#### eval Validate ($val, $dirData, $subdirStart, $size)
                local ok = 0
                if subdir.Validate ~= nil and not perlTruthy(subdir.Validate(et, val, dirData, subdirStart, size)) then
                    et:Warn('Invalid ' .. tagStr .. ' data', inMakerNotes)
                    invalid = 1
                else
                    if not perlTruthy(subdirInfo.DirName) and inMakerNotes then
                        subdirInfo.DirName = tagInfo.Name
                    end
                    -- process the subdirectory
                    ok = et:ProcessDirectory(subdirInfo, newTagTable, subdir.ProcessProc)
                end
                -- print debugging information if there were errors
                if not perlTruthy(ok) and verbose > 1 and subdirStart ~= valuePtr then
                    local out = et:Options('TextOut')
                    perl.printf(out, "%s    (SubDirectory start = 0x%x)\n", et.INDENT, subdirStart)
                end
                ExifTool.SetByteOrder(oldByteOrder)    -- restore original byte swapping

                if #values == 0 then break end
                val = table.remove(values, 1)           -- continue with next subdir
                dirNum = dirNum + 1
            end
            local doMaker = et:Options('MakerNotes')
            if not (perlTruthy(doMaker) or (et.REQ_TAG_LOOKUP and et.REQ_TAG_LOOKUP[lc(tagStr)]) or
                    perlTruthy(tagInfo.BlockExtract)) then goto continue end
            -- extract as a block if specified
            if tagInfo.MakerNotes then
                -- save maker note byte order (if it was significant and valid)
                if subdir.ByteOrder and not invalid then
                    if et.UnknownByteOrder ~= nil then
                        et.MAKER_NOTE_BYTE_ORDER = et.UnknownByteOrder
                    else
                        et.MAKER_NOTE_BYTE_ORDER = newByteOrder
                    end
                end
                if doMaker and perlStr(doMaker) == '2' then
                    -- extract maker notes without rebuilding (no fixup information)
                    et.MAKER_NOTE_FIXUP = nil
                elseif not tagInfo.NotIFD or tagInfo.IsPhaseOne then
                    -- this is a pain, but we must rebuild EXIF-type maker notes to
                    -- include all the value data if data was outside the maker notes
                    local makerDirInfo = {
                        Name       = tagStr,
                        Base       = base,
                        DataPt     = valueDataPt,
                        DataPos    = valueDataPos,
                        DataLen    = valueDataLen,
                        DirStart   = valuePtr,
                        DirLen     = size,
                        RAF        = raf,
                        Parent     = dirName,
                        DirName    = 'MakerNotes',
                        FixOffsets = subdir.FixOffsets,
                        TagInfo    = tagInfo,
                    }
                    local val2
                    if tagInfo.IsPhaseOne then
                        et.DropTags = 1
                        val2 = require('lexiftool.PhaseOne').WritePhaseOne(et, makerDirInfo, newTagTable)
                        et.DropTags = nil
                    else
                        if subdir.FixBase then makerDirInfo.FixBase = 1 end
                        -- rebuild maker notes (creates $$et{MAKER_NOTE_FIXUP})
                        val2 = require('lexiftool.WriteExif').RebuildMakerNotes(et, makerDirInfo, newTagTable)
                    end
                    if val2 ~= nil then
                        val = val2
                    elseif size > 4 then
                        et:Warn('Error rebuilding maker notes (may be corrupt)')
                    end
                end
            else
                -- extract this directory as a block if specified
                if not perlTruthy(tagInfo.Writable) then goto continue end
            end
        end

        -- convert to absolute offsets if this tag is an offset
        --#### eval IsOffset ($val, $et)
        -- (an IsOffset condition string is a Lua function(et, val) in the port)
        if tagInfo.IsOffset and (type(tagInfo.IsOffset) ~= 'function' or
            perlTruthy(tagInfo.IsOffset(et, val)))
        then
            local offsetBase = perlStr(tagInfo.IsOffset) == '2' and firstBase or base
            offsetBase = offsetBase + (et.BASE or 0)
            -- handle offsets which use a wrong base (Minolta A200)
            if tagInfo.WrongBase then
                local self = et
                --#### eval WrongBase ($self)
                offsetBase = offsetBase + (perl.num(tagInfo.WrongBase(self)) or 0)
            end
            local vals = split(' ',val)
            for k = 1, #vals do
                vals[k] = perl.num(vals[k]) + offsetBase
            end
            val = perl.join(' ', vals)
        end
        if validate or doHash then
            if tagInfo.OffsetPair then
                offsetInfo[tagID] = { tagInfo, val }
            elseif Exif.saveForValidate[tagID] and isExif then
                offsetInfo[tagID] = val
            end
        end
        -- save the value of this tag
        local tagKey = et:FoundTag(tagInfo, val)
        if tagKey then
            -- set the group 1 name for tags in specified tables
            if tagTablePtr.SET_GROUP1 then
                et:SetGroup(tagKey, dirName)
            end
            -- save original components of rational numbers
            if rational then et.TAG_EXTRA[tagKey].Rational = rational end
            if et.MAKER_NOTE_FIXUP then
                et.TAG_EXTRA[tagKey].Fixup = et.MAKER_NOTE_FIXUP
                et.MAKER_NOTE_FIXUP = nil
            end
        end
        ::continue::
    end

    if next(offsetInfo) ~= nil then
        -- calculate image data hash if requested
        if doHash then require('lexiftool.WriteExif').AddImageDataHash(et, dirInfo, offsetInfo) end
        -- validate image data offsets for this IFD (note: modifies offsetInfo)
        if validate then require('lexiftool.Validate').ValidateOffsetInfo(et, offsetInfo, dirName, inMakerNotes) end
    end

    -- scan for subsequent IFD's if specified
    if perlTruthy(dirInfo.Multi) and bytesFromEnd >= 4 then
        -- use same directory information for trailing directory,
        -- but change the start location (ProcessDirectory will
        -- test to make sure we don't reprocess the same dir twice)
        local newDirInfo = {}
        for k, v in pairs(dirInfo) do newDirInfo[k] = v end
        newDirInfo.Multi = 0  -- prevent recursion
        newDirInfo.OffsetName = nextOffName
        et.INDENT = et.INDENT:sub(1, -3) -- keep indent the same
        while true do
            local offset = et.Get32u(dataPt, dirEnd)
            if offset == 0 then break end
            newDirInfo.DirStart = offset - dataPos
            -- increment IFD number
            local prefix, ifdNum = perlStr(newDirInfo.DirName):match('^(.-)(%d*)$')
            newDirInfo.DirName = prefix .. ((tonumber(ifdNum) or 0) + 1)
            -- must validate SubIFD1 because the nextIFD pointer is invalid for some RAW formats
            if newDirInfo.DirName ~= 'SubIFD1' or perlTruthy(require('lexiftool.WriteExif').ValidateIFD(newDirInfo)) then
                local cur = table.remove(et.PATH)
                if not perlTruthy(et:ProcessDirectory(newDirInfo, tagTablePtr)) then success = 0 end
                et.PATH[#et.PATH + 1] = cur
                if perlTruthy(success) and (newDirInfo.BytesFromEnd or 0) >= 4 then
                    dataPt = newDirInfo.DataPt
                    dataPos = newDirInfo.DataPos
                    dirEnd = newDirInfo.DirEnd
                    goto nextIFD
                end
            elseif perlTruthy(et.OPTIONS.Verbose) or et.TIFF_TYPE == 'TIFF' then
                et:Warn('Ignored bad IFD linked from SubIFD')
            end
            break
            ::nextIFD::
        end
    elseif dirInfo.Multi ~= nil then
        -- return the parameters the caller needs for parsing the next IFD
        dirInfo.DirEnd = dirEnd
        dirInfo.OffsetName = nextOffName
        dirInfo.BytesFromEnd = bytesFromEnd
        dirInfo.DataPt = dataPt
        dirInfo.DataPos = dataPos
    end
    return success
end

return Exif
