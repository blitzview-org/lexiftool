--------------------------------------------------------------------------------
-- File:         lexiftool/Charset.lua
-- Ported from:  lib/Image/ExifTool/Charset.pm
--
-- Description:  ExifTool character encoding routines
--
-- Revisions:    2009/08/28 - P. Harvey created
--               2010/01/20 - P. Harvey complete re-write
--               2010/07/16 - P. Harvey added UTF-16 support
--
-- Notes:        Charset lookups are generated using my convertCharset script
--
-- Port notes:   full port of LoadCharset, IsUTF16, Decompose and Recompose.
--               The lookup tables live in lexiftool/Charset/<Name>.lua, one
--               per upstream Charset/<Name>.pm.  UTF-8 is decoded by the
--               local unpackC0U, which reproduces unpack('C0U*') (see
--               there), with the same one-time warning -- which Perl
--               raises with and without `-w`.
--------------------------------------------------------------------------------

local Charset = {}

local perl = require('lexiftool.perl')
local unpack, pack, subst = perl.unpack, perl.pack, perl.subst
local uc = perl.uc

-- (upstream imports GetByteOrder from Image::ExifTool; this module is loaded
--  while lexiftool.lua itself is still loading, so the lookup is deferred)
local function GetByteOrder()
    return require('lexiftool').GetByteOrder()
end

-- unpack('C0U*', $val) as Perl does it under `-w` (exiftool's #! line):
-- Perl's lax UTF-8 -- surrogates, non-characters and code points above
-- 0x10ffff (5- to 13-byte sequences) are accepted, but a malformed sequence
-- (a stray continuation byte, a start byte followed by too few continuation
-- bytes, an overlong encoding) yields one 0 for the bytes it spans and a
-- warning.  Lua's utf8 library rejects part of what Perl accepts and stops at
-- the first error, so it can't stand in here.  Checked against perl 5.42.
-- Returns: 1) list of code points, 2) true if a sequence was malformed
local utf8Min = { [2] = 0x80, [3] = 0x800, [4] = 0x10000, [5] = 0x200000,
                  [6] = 0x4000000, [7] = 0x80000000, [13] = 1 << 36 }
local function unpackC0U(val)
    local uni, bad = {}, false
    local i, n = 1, #val
    while i <= n do
        local c = val:byte(i)
        local len, cp
        if     c < 0x80 then len, cp = 1, c
        elseif c < 0xc0 then len = 0             -- unexpected continuation byte
        elseif c < 0xe0 then len, cp = 2, c & 0x1f
        elseif c < 0xf0 then len, cp = 3, c & 0x0f
        elseif c < 0xf8 then len, cp = 4, c & 0x07
        elseif c < 0xfc then len, cp = 5, c & 0x03
        elseif c < 0xfe then len, cp = 6, c & 0x01
        elseif c == 0xfe then len, cp = 7, 0
        else                  len, cp = 13, 0
        end
        i = i + 1
        if len == 0 then
            uni[#uni + 1] = 0
            bad = true
        else
            local got = 1
            while got < len do
                local b = val:byte(i)
                if not b or b & 0xc0 ~= 0x80 then break end
                cp = (cp << 6) | (b & 0x3f)
                i = i + 1
                got = got + 1
            end
            if got < len or (len > 1 and cp < utf8Min[len]) then
                uni[#uni + 1] = 0     -- too short or overlong
                bad = true
            else
                uni[#uni + 1] = cp
            end
        end
    end
    return uni, bad
end

-- pack(FMT, @list) for a list of any length (Lua's table.unpack is bounded
-- by the C stack, Perl's argument list is not)
local function packList(fmt, list)
    local out = {}
    for i = 1, #list, 4096 do
        out[#out + 1] = pack(fmt, table.unpack(list, i, math.min(i + 4095, #list)))
    end
    return table.concat(out)
end

local charsetTable = {}   -- character set tables we've loaded

-- lookup for converting Unicode to 1-byte character sets
local unicode2byte = {
  Latin = {    -- pre-load Latin (cp1252) for speed
    [0x20ac] = 0x80,  [0x0160] = 0x8a,  [0x2013] = 0x96,
    [0x201a] = 0x82,  [0x2039] = 0x8b,  [0x2014] = 0x97,
    [0x0192] = 0x83,  [0x0152] = 0x8c,  [0x02dc] = 0x98,
    [0x201e] = 0x84,  [0x017d] = 0x8e,  [0x2122] = 0x99,
    [0x2026] = 0x85,  [0x2018] = 0x91,  [0x0161] = 0x9a,
    [0x2020] = 0x86,  [0x2019] = 0x92,  [0x203a] = 0x9b,
    [0x2021] = 0x87,  [0x201c] = 0x93,  [0x0153] = 0x9c,
    [0x02c6] = 0x88,  [0x201d] = 0x94,  [0x017e] = 0x9e,
    [0x2030] = 0x89,  [0x2022] = 0x95,  [0x0178] = 0x9f,
  },
}

-- bit flags for all supported character sets
-- (this number must be correct because it dictates the decoding algorithm!)
--   0x001 = character set requires a translation module
--   0x002 = inverse conversion not yet supported by Recompose()
--   0x080 = some characters with codepoints in the range 0x00-0x7f are remapped
--   0x100 = 1-byte fixed-width characters
--   0x200 = 2-byte fixed-width characters
--   0x400 = 4-byte fixed-width characters
--   0x800 = 1- and 2-byte variable-width characters, or 1-byte
--           fixed-width characters that map into multiple codepoints
-- Note: In its public interface, ExifTool can currently only support type 0x101
--       and lower character sets because strings are only converted if they
--       contain characters above 0x7f and there is no provision for specifying
--       the byte order for input/output values
local csType = {
    UTF8         = 0x100,
    ASCII        = 0x100, -- (treated like UTF8)
    Arabic       = 0x101,
    Baltic       = 0x101,
    Cyrillic     = 0x101,
    Greek        = 0x101,
    Hebrew       = 0x101,
    Latin        = 0x101,
    Latin2       = 0x101,
    DOSLatinUS   = 0x101,
    DOSLatin1    = 0x101,
    DOSCyrillic  = 0x101,
    MacCroatian  = 0x101,
    MacCyrillic  = 0x101,
    MacGreek     = 0x101,
    MacIceland   = 0x101,
    MacLatin2    = 0x101,
    MacRoman     = 0x101,
    MacRomanian  = 0x101,
    MacTurkish   = 0x101,
    Thai         = 0x101,
    Turkish      = 0x101,
    Vietnam      = 0x101,
    MacArabic    = 0x103, -- (directional characters not supported)
    PDFDoc       = 0x181,
    Unicode      = 0x200, -- (UCS2)
    UCS2         = 0x200,
    UTF16        = 0x200, -- (UCS2 with surrogate pairs added)
    Symbol       = 0x201,
    JIS          = 0x201,
    UCS4         = 0x400, -- (UTF32)
    MacChineseCN = 0x803,
    MacChineseTW = 0x803,
    MacHebrew    = 0x803, -- (directional characters not supported)
    MacKorean    = 0x803,
    MacRSymbol   = 0x803,
    MacThai      = 0x803,
    MacJapanese  = 0x883,
    ShiftJIS     = 0x883,
}
Charset.csType = csType

--------------------------------------------------------------------------------
-- Load character set module
-- Inputs: 0) Module name
-- Returns: Reference to lookup hash, or undef on error
function Charset.LoadCharset(charset)
    local conv = charsetTable[charset]
    if not conv then
        -- load translation module
        local ok, module = pcall(require, 'lexiftool.Charset.' .. charset)
        if ok and type(module) == 'table' and module[charset] then
            conv = module[charset]
            charsetTable[charset] = conv
        end
    end
    return conv
end

--------------------------------------------------------------------------------
-- Does an array contain valid UTF-16 characters?
-- Inputs: 0) array reference to list of UCS-2 values
-- Returns: 0=invalid UTF-16, 1=valid UTF-16 with no surrogates, 2=valid UTF-16 with surrogates
function Charset.IsUTF16(uni)
    local surrogate
    for _, v in ipairs(uni) do
        local hiBits = (v & 0xfc00)
        if hiBits == 0xfc00 then
            -- check for invalid values in UTF-16
            if v == 0xffff or v == 0xfffe or (v >= 0xfdd0 and v <= 0xfdef) then return 0 end
        elseif surrogate == 1 then
            if hiBits ~= 0xdc00 then return 0 end
            surrogate = 0
        else
            if hiBits == 0xdc00 then return 0 end
            if hiBits == 0xd800 then surrogate = 1 end
        end
    end
    if surrogate == nil then return 1 end
    if surrogate == 0 then return 2 end
    return 0
end

--------------------------------------------------------------------------------
-- Decompose string with specified encoding into an array of integer code points
-- Inputs: 0) ExifTool object ref (or undef), 1) string, 2) character set name,
--         3) optional byte order ('II','MM','Unknown' or undef to use ExifTool ordering)
-- Returns: Reference to array of Unicode values
-- Notes: Accepts any type of character set
-- - byte order only used for fixed-width 2-byte and 4-byte character sets
-- - byte order mark observed and then removed with UCS2 and UCS4
-- - no warnings are issued if ExifTool object is not provided
-- - sets ExifTool WrongByteOrder flag if byte order is Unknown and current order is wrong
function Charset.Decompose(et, val, charset, byteOrder)
    local type_ = csType[charset] or 0 -- (Perl: undef & 0x001 is 0)
    local uni, conv = {}, nil

    if type_ & 0x001 ~= 0 then
        conv = Charset.LoadCharset(charset)
        if not conv then
            -- (shouldn't happen)
            if et then et:Warn('Invalid character set ' .. charset) end
            return uni      -- error!
        end
    elseif type_ == 0x100 then
        -- convert ASCII and UTF8 (treat ASCII as UTF8)
        -- handle warnings from malformed UTF-8
        local evalWarning
        -- (upstream: unpack('C0U*', $val) with $SIG{'__WARN__'} set)
        uni, evalWarning = unpackC0U(val)
        -- (Perl's "Malformed UTF-8 character" warnings are default-on, so
        --  SetWarning catches them with and without `-w`/`$^W`: checked
        --  against perl 5.42, library call without -w included)
        -- issue warning if we had errors
        if evalWarning then
            if et and not et.WarnBadUTF8 then
                et:Warn('Malformed UTF-8 character(s)')
                et.WarnBadUTF8 = 1
            end
        end
        return uni          -- all done!
    end
    if type_ & 0x100 ~= 0 then      -- 1-byte fixed-width characters
        uni = { unpack('C*', val) }
        for i, v in ipairs(uni) do
            if conv[v] ~= nil then uni[i] = conv[v] end
        end
    elseif type_ & 0x600 ~= 0 then  -- 2-byte or 4-byte fixed-width characters
        local unknown
        if not byteOrder then
            byteOrder = GetByteOrder()
        elseif byteOrder == 'Unknown' then
            byteOrder = GetByteOrder()
            unknown = 1
        end
        local fmt = byteOrder == 'MM' and 'n*' or 'v*'
        if type_ & 0x400 ~= 0 then  -- 4-byte
            fmt = uc(fmt) -- unpack as 'N*' or 'V*'
            -- honour BOM if it exists
            local bom = perl.matches(val, [[^(\0\0\xfe\xff|\xff\xfe\0\0)]])
            if bom then
                val = val:sub(5)
                fmt = bom == '\0\0\xfe\xff' and 'N*' or 'V*'
            end
            unknown = nil -- (byte order logic applies to 2-byte only)
        else
            local bom = perl.matches(val, [[^(\xfe\xff|\xff\xfe)]])
            if bom then
                val = val:sub(3)
                fmt = bom == '\xfe\xff' and 'n*' or 'v*'
                unknown = nil
            end
        end
        -- convert from UCS2 or UCS4
        uni = { unpack(fmt, val) }

        if not conv then
            -- no translation necessary
            if unknown then
                -- check the byte order
                local bh, bl = {}, {}
                local nbh, nbl = 0, 0
                local zh, zl = 0, 0
                for _, v in ipairs(uni) do
                    if not bh[v >> 8] then bh[v >> 8] = 1; nbh = nbh + 1 end
                    if not bl[v & 0xff] then bl[v & 0xff] = 1; nbl = nbl + 1 end
                    if v & 0xff00 == 0 then zh = zh + 1 end
                    if v & 0x00ff == 0 then zl = zl + 1 end
                end
                -- count the number of unique values in the hi and lo bytes
                -- the byte with the greater number of unique values should be
                -- the low-order byte, otherwise the byte which is zero more
                -- often is likely the high-order byte
                if nbh > nbl or (nbh == nbl and zl > zh) then
                    -- we guessed wrong, so decode using the other byte order
                    fmt = perl.tr(fmt, 'nvNV', 'vnVN')
                    uni = { unpack(fmt, val) }
                    if et then et.WrongByteOrder = 1 end
                end
            end
            -- handle surrogate pairs of UTF-16
            if charset == 'UTF16' then
                local i = 1
                while i < #uni do
                    if (uni[i] & 0xfc00) == 0xd800 and (uni[i + 1] & 0xfc00) == 0xdc00 then
                        local cp = 0x10000 + ((uni[i] & 0x3ff) << 10) + (uni[i + 1] & 0x3ff)
                        table.remove(uni, i + 1)
                        uni[i] = cp
                    end
                    i = i + 1
                end
            end
        elseif unknown then
            -- count encoding errors as we do the translation
            local e1 = 0
            for i, v in ipairs(uni) do
                if conv[v] ~= nil then uni[i] = conv[v] else e1 = e1 + 1 end
            end
            -- try the other byte order if we had any errors
            if e1 > 0 then
                fmt = byteOrder == 'MM' and 'v*' or 'n*' --(reversed)
                local try = { unpack(fmt, val) }
                local e2 = 0
                for i, v in ipairs(try) do
                    if conv[v] ~= nil then try[i] = conv[v] else e2 = e2 + 1 end
                end
                -- use this byte order if there are fewer errors
                if e2 < e1 then
                    if et then et.WrongByteOrder = 1 end
                    return try
                end
            end
        else
            -- translate any characters found in the lookup
            for i, v in ipairs(uni) do
                if conv[v] ~= nil then uni[i] = conv[v] end
            end
        end
    else                            -- variable-width characters
        -- unpack into bytes
        local bytes = { unpack('C*', val) }
        local i = 1
        while i <= #bytes do
            local ch = bytes[i]
            i = i + 1
            local cv = conv[ch]
            if not cv then
                -- pass straight through if no translation
                uni[#uni + 1] = ch
            elseif type(cv) ~= 'table' then
                -- byte translates into single Unicode character
                uni[#uni + 1] = cv
            elseif #cv > 0 then
                -- byte maps into multiple Unicode characters
                for _, c in ipairs(cv) do uni[#uni + 1] = c end
            else
                -- handle 2-byte character codes
                ch = bytes[i]
                i = i + 1
                if ch ~= nil then
                    if cv[ch] then
                        cv = cv[ch]
                        if type(cv) ~= 'table' then
                            uni[#uni + 1] = cv
                        else
                            for _, c in ipairs(cv) do uni[#uni + 1] = c end -- multiple Unicode characters
                        end
                    else
                        uni[#uni + 1] = ('?'):byte()    -- encoding error
                        i = i - 1   -- (upstream: unshift @bytes, $ch)
                    end
                else
                    uni[#uni + 1] = ('?'):byte()        -- encoding error
                end
            end
        end
    end
    return uni
end

--------------------------------------------------------------------------------
-- Convert array of code point integers into a string with specified encoding
-- Inputs: 0) ExifTool ref (or undef), 1) unicode character array ref,
--         2) character set (note: not all types are supported)
--         3) byte order ('MM' or 'II', multi-byte sets only, defaults to current byte order)
-- Returns: converted string (truncated at null character if it exists), empty on error
-- Notes: converts elements of input character array to new code points
-- - ExifTool ref may be undef provided $charset is defined
function Charset.Recompose(et, uni, charset, byteOrder)
    local outVal, conv, inv
    if not charset then charset = et.OPTIONS.Charset end
    local csType_ = csType[charset] or 0 -- (Perl: undef & 0x801 is 0)
    if csType_ == 0x100 then        -- UTF8 (also treat ASCII as UTF8)
        -- (upstream: pack('C0U*', @$uni))
        local out = {}
        for i, cp in ipairs(uni) do out[i] = utf8.char(cp) end
        outVal = table.concat(out)
        outVal = subst(outVal, [[(?s)\0.*]], '')   -- truncate at null terminator
        return outVal
    end
    -- get references to forward and inverse lookup tables
    if csType_ & 0x801 ~= 0 then
        conv = Charset.LoadCharset(charset)
        if not conv then
            if et then et:Warn('Missing charset ' .. charset) end
            return ''
        end
        inv = unicode2byte[charset]
        -- generate inverse lookup if necessary
        if not inv then
            if csType_ == 0 or csType_ & 0x802 ~= 0 then
                if et then et:Warn('Invalid destination charset ' .. charset) end
                return ''
            end
            -- prepare table to convert from Unicode to 1-byte characters
            inv = {}
            for char, v in pairs(conv) do
                inv[v] = char
            end
            unicode2byte[charset] = inv
        end
    end
    if csType_ & 0x100 ~= 0 then    -- 1-byte fixed-width
        -- convert to specified character set
        for i, v in ipairs(uni) do
            if v < 0x80 then -- luacheck: ignore 542
                -- (next)
            elseif inv[v] then
                uni[i] = inv[v]
            -- our tables omit 1-byte characters with the same values as Unicode,
            -- so pass them straight through after making sure there isn't a
            -- different character with this byte value
            elseif v < 0x100 and not conv[v] then -- luacheck: ignore 542
                -- (next)
            else
                uni[i] = ('?'):byte()  -- set invalid characters to '?'
                if et and not et.EncodingError then
                    et:Warn('Some character(s) could not be encoded in ' .. charset)
                    et.EncodingError = 1
                end
            end
        end
        -- repack as an 8-bit string and truncate at null
        outVal = packList('C*', uni)
        outVal = subst(outVal, [[(?s)\0.*]], '')
    else                            -- 2-byte and 4-byte fixed-width
        -- convert if required
        if inv then
            for i, v in ipairs(uni) do
                if inv[v] then uni[i] = inv[v] end
            end
        end
        -- generate surrogate pairs of UTF-16
        if charset == 'UTF16' then
            local i = 1
            while i <= #uni do
                if uni[i] >= 0x10000 and uni[i] < 0x10ffff then
                    local t = uni[i] - 0x10000
                    local w1 = 0xd800 + ((t >> 10) & 0x3ff)
                    local w2 = 0xdc00 + (t & 0x3ff)
                    uni[i] = w1
                    table.insert(uni, i + 1, w2)
                    i = i + 1   -- skip surrogate pair
                end
                i = i + 1
            end
        end
        -- pack as 2- or 4-byte integer in specified byte order
        byteOrder = byteOrder or GetByteOrder()
        local fmt = byteOrder == 'MM' and 'n*' or 'v*'
        if csType_ & 0x400 ~= 0 then fmt = uc(fmt) end
        outVal = packList(fmt, uni)
    end
    return outVal
end

return Charset
