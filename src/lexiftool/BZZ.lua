--------------------------------------------------------------------------------
-- File:         lexiftool/BZZ.lua
-- Ported from:  lib/Image/ExifTool/BZZ.pm
--
-- Description:  Utility to decode BZZ compressed data
--
-- Revisions:    09/22/2008 - P. Harvey Created
--
-- References:   1) http://djvu.sourceforge.net/
--               2) http://www.djvu.org/
--
-- Notes:        This code based on ZPCodec and BSByteStream of DjVuLibre 3.5.21
--               (see NOTES documentation below for license/copyright details)
--
-- Port notes:   Complete port of BZZ.pm: every sub, in upstream order.
--               decoder()/decode_sub() update a slot of the shared `ctx`
--               array through Perl's @_ aliasing (`$_[2] = ...`); Lua has no
--               such aliasing, so they take the context array and index
--               (cx, idx) and write back into cx[idx] -- the same effect.
--               All arithmetic is integer, as upstream's `use integer`.
--------------------------------------------------------------------------------

local BZZ = {}
BZZ.__index = BZZ

-- constants
local function FREQMAX() return 4 end
local function CTXIDS() return 3 end
local function MAXBLOCK() return 4096 end
BZZ.FREQMAX, BZZ.CTXIDS, BZZ.MAXBLOCK = FREQMAX, CTXIDS, MAXBLOCK

-- This table has been designed for the ZPCoder
-- by running the following command in file 'zptable.sn':
-- (fast-crude (steady-mat 0.0035  0.0002) 260)))
local default_ztable_p = {
    [0] = 0x8000, 0x8000, 0x8000, 0x6bbd, 0x6bbd, 0x5d45, 0x5d45, 0x51b9, 0x51b9, 0x4813,
    0x4813, 0x3fd5, 0x3fd5, 0x38b1, 0x38b1, 0x3275, 0x3275, 0x2cfd, 0x2cfd, 0x2825,
    0x2825, 0x23ab, 0x23ab, 0x1f87, 0x1f87, 0x1bbb, 0x1bbb, 0x1845, 0x1845, 0x1523,
    0x1523, 0x1253, 0x1253, 0x0fcf, 0x0fcf, 0x0d95, 0x0d95, 0x0b9d, 0x0b9d, 0x09e3,
    0x09e3, 0x0861, 0x0861, 0x0711, 0x0711, 0x05f1, 0x05f1, 0x04f9, 0x04f9, 0x0425,
    0x0425, 0x0371, 0x0371, 0x02d9, 0x02d9, 0x0259, 0x0259, 0x01ed, 0x01ed, 0x0193,
    0x0193, 0x0149, 0x0149, 0x010b, 0x010b, 0x00d5, 0x00d5, 0x00a5, 0x00a5, 0x007b,
    0x007b, 0x0057, 0x0057, 0x003b, 0x003b, 0x0023, 0x0023, 0x0013, 0x0013, 0x0007,
    0x0007, 0x0001, 0x0001, 0x5695, 0x24ee, 0x8000, 0x0d30, 0x481a, 0x0481, 0x3579,
    0x017a, 0x24ef, 0x007b, 0x1978, 0x0028, 0x10ca, 0x000d, 0x0b5d, 0x0034, 0x078a,
    0x00a0, 0x050f, 0x0117, 0x0358, 0x01ea, 0x0234, 0x0144, 0x0173, 0x0234, 0x00f5,
    0x0353, 0x00a1, 0x05c5, 0x011a, 0x03cf, 0x01aa, 0x0285, 0x0286, 0x01ab, 0x03d3,
    0x011a, 0x05c5, 0x00ba, 0x08ad, 0x007a, 0x0ccc, 0x01eb, 0x1302, 0x02e6, 0x1b81,
    0x045e, 0x24ef, 0x0690, 0x2865, 0x09de, 0x3987, 0x0dc8, 0x2c99, 0x10ca, 0x3b5f,
    0x0b5d, 0x5695, 0x078a, 0x8000, 0x050f, 0x24ee, 0x0358, 0x0d30, 0x0234, 0x0481,
    0x0173, 0x017a, 0x00f5, 0x007b, 0x00a1, 0x0028, 0x011a, 0x000d, 0x01aa, 0x0034,
    0x0286, 0x00a0, 0x03d3, 0x0117, 0x05c5, 0x01ea, 0x08ad, 0x0144, 0x0ccc, 0x0234,
    0x1302, 0x0353, 0x1b81, 0x05c5, 0x24ef, 0x03cf, 0x2b74, 0x0285, 0x201d, 0x01ab,
    0x1715, 0x011a, 0x0fb7, 0x00ba, 0x0a67, 0x01eb, 0x06e7, 0x02e6, 0x0496, 0x045e,
    0x030d, 0x0690, 0x0206, 0x09de, 0x0155, 0x0dc8, 0x00e1, 0x2b74, 0x0094, 0x201d,
    0x0188, 0x1715, 0x0252, 0x0fb7, 0x0383, 0x0a67, 0x0547, 0x06e7, 0x07e2, 0x0496,
    0x0bc0, 0x030d, 0x1178, 0x0206, 0x19da, 0x0155, 0x24ef, 0x00e1, 0x320e, 0x0094,
    0x432a, 0x0188, 0x447d, 0x0252, 0x5ece, 0x0383, 0x8000, 0x0547, 0x481a, 0x07e2,
    0x3579, 0x0bc0, 0x24ef, 0x1178, 0x1978, 0x19da, 0x2865, 0x24ef, 0x3987, 0x320e,
    0x2c99, 0x432a, 0x3b5f, 0x447d, 0x5695, 0x5ece, 0x8000, 0x8000, 0x5695, 0x481a,
    0x481a, 0, 0, 0, 0, 0
}
local default_ztable_m = {
    [0] = 0x0000, 0x0000, 0x0000, 0x10a5, 0x10a5, 0x1f28, 0x1f28, 0x2bd3, 0x2bd3, 0x36e3,
    0x36e3, 0x408c, 0x408c, 0x48fd, 0x48fd, 0x505d, 0x505d, 0x56d0, 0x56d0, 0x5c71,
    0x5c71, 0x615b, 0x615b, 0x65a5, 0x65a5, 0x6962, 0x6962, 0x6ca2, 0x6ca2, 0x6f74,
    0x6f74, 0x71e6, 0x71e6, 0x7404, 0x7404, 0x75d6, 0x75d6, 0x7768, 0x7768, 0x78c2,
    0x78c2, 0x79ea, 0x79ea, 0x7ae7, 0x7ae7, 0x7bbe, 0x7bbe, 0x7c75, 0x7c75, 0x7d0f,
    0x7d0f, 0x7d91, 0x7d91, 0x7dfe, 0x7dfe, 0x7e5a, 0x7e5a, 0x7ea6, 0x7ea6, 0x7ee6,
    0x7ee6, 0x7f1a, 0x7f1a, 0x7f45, 0x7f45, 0x7f6b, 0x7f6b, 0x7f8d, 0x7f8d, 0x7faa,
    0x7faa, 0x7fc3, 0x7fc3, 0x7fd7, 0x7fd7, 0x7fe7, 0x7fe7, 0x7ff2, 0x7ff2, 0x7ffa,
    0x7ffa, 0x7fff, 0x7fff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
}
local default_ztable_up = {
     [0] = 84,   3,   4,   5,   6,   7,   8,   9,  10,  11,  12,  13,  14,  15,  16,  17,
     18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,  32,  33,
     34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,  45,  46,  47,  48,  49,
     50,  51,  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,  62,  63,  64,  65,
     66,  67,  68,  69,  70,  71,  72,  73,  74,  75,  76,  77,  78,  79,  80,  81,
     82,  81,  82,   9,  86,   5,  88,  89,  90,  91,  92,  93,  94,  95,  96,  97,
     82,  99,  76, 101,  70, 103,  66, 105, 106, 107,  66, 109,  60, 111,  56,  69,
    114,  65, 116,  61, 118,  57, 120,  53, 122,  49, 124,  43,  72,  39,  60,  33,
     56,  29,  52,  23,  48,  23,  42, 137,  38,  21, 140,  15, 142,   9, 144, 141,
    146, 147, 148, 149, 150, 151, 152, 153, 154, 155,  70, 157,  66,  81,  62,  75,
     58,  69,  54,  65,  50, 167,  44,  65,  40,  59,  34,  55,  30, 175,  24, 177,
    178, 179, 180, 181, 182, 183, 184,  69, 186,  59, 188,  55, 190,  51, 192,  47,
    194,  41, 196,  37, 198, 199,  72, 201,  62, 203,  58, 205,  54, 207,  50, 209,
     46, 211,  40, 213,  36, 215,  30, 217,  26, 219,  20,  71,  14,  61,  14,  57,
      8,  53, 228,  49, 230,  45, 232,  39, 234,  35, 138,  29,  24,  25, 240,  19,
     22,  13,  16,  13,  10,   7, 244, 249,  10,  89, 230, 0, 0, 0, 0, 0
}
local default_ztable_dn = {
    [0] = 145,   4,   3,   1,   2,   3,   4,   5,   6,   7,   8,   9,  10,  11,  12,  13,
     14,  15,  16,  17,  18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,
     30,  31,  32,  33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,  45,
     46,  47,  48,  49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,
     62,  63,  64,  65,  66,  67,  68,  69,  70,  71,  72,  73,  74,  75,  76,  77,
     78,  79,  80,  85, 226,   6, 176, 143, 138, 141, 112, 135, 104, 133, 100, 129,
     98, 127,  72, 125, 102, 123,  60, 121, 110, 119, 108, 117,  54, 115,  48, 113,
    134,  59, 132,  55, 130,  51, 128,  47, 126,  41,  62,  37,  66,  31,  54,  25,
     50, 131,  46,  17,  40,  15, 136,   7,  32, 139, 172,   9, 170,  85, 168, 248,
    166, 247, 164, 197, 162,  95, 160, 173, 158, 165, 156, 161,  60, 159,  56,  71,
     52, 163,  48,  59,  42, 171,  38, 169,  32,  53,  26,  47, 174, 193,  18, 191,
    222, 189, 218, 187, 216, 185, 214,  61, 212,  53, 210,  49, 208,  45, 206,  39,
    204, 195, 202,  31, 200, 243,  64, 239,  56, 237,  52, 235,  48, 233,  44, 231,
     38, 229,  34, 227,  28, 225,  22, 223,  16, 221, 220,  63,   8,  55, 224,  51,
      2,  47,  87,  43, 246,  37, 244,  33, 238,  27, 236,  21,  16,  15,   8, 241,
    242,   7,  10, 245,   2,   1,  83, 250,   2, 143, 246, 0, 0, 0, 0, 0
}

--------------------------------------------------------------------------------
-- New - create new BZZ object
-- Inputs: 0) reference to BZZ object or BZZ class name
-- Returns: blessed BZZ object ref
function BZZ.new()
    return setmetatable({}, BZZ)
end

--------------------------------------------------------------------------------
-- Initialize BZZ object
-- Inputs: 0) BZZ object ref, 1) data ref, 2) true for DjVu compatibility
function BZZ:Init(dataPt, djvucompat)
    -- Create machine independent ffz table
    local ffzt = {}
    self.ffzt = ffzt
    for i = 0, 255 do
        ffzt[i] = 0
        local j = i
        while j & 0x80 ~= 0 do
            ffzt[i] = ffzt[i] + 1
            j = j << 1
        end
    end
    -- Initialize table
    local function copy(t) local c = {} for k = 0, #t do c[k] = t[k] end return c end
    self.p = copy(default_ztable_p)
    self.m = copy(default_ztable_m)
    self.up = copy(default_ztable_up)
    self.dn = copy(default_ztable_dn)
    -- Patch table (and lose DjVu compatibility)
    if not djvucompat then
        local p, m, dn = self.p, self.m, self.dn
        for j = 0, 255 do
            local a = (0x10000 - p[j]) & 0xffff
            while a >= 0x8000 do a = (a << 1) & 0xffff end
            if m[j] > 0 and a + p[j] >= 0x8000 and a >= m[j] then
                dn[j] = default_ztable_dn[default_ztable_dn[j]]
            end
        end
    end
    self.ctx = {}
    for i = 0, 299 do self.ctx[i] = 0 end
    self.DataPt = dataPt
    self.Pos = 0
    self.DataLen = #dataPt
    self.a = 0
    self.buffer = 0
    self.fence = 0
    self.blocksize = 0
    -- Read first 16 bits of code
    if #dataPt >= 2 then
        self.code = string.unpack('>I2', dataPt)
        self.Pos = self.Pos + 2
    elseif #dataPt >= 1 then
        self.code = (string.byte(dataPt, 1) << 8) | 0xff
        self.Pos = self.Pos + 1
    else
        self.code = 0xffff
    end
    self.byte = self.code & 0xff
    -- Preload buffer
    self.delay = 25
    self.scount = 0
    -- Compute initial fence
    self.fence = self.code >= 0x8000 and 0x7fff or self.code
end

--------------------------------------------------------------------------------
-- Decode data block
-- Inputs: 0) optional BZZ object ref, 1) optional data ref
-- Returns: decoded data or undefined on error
-- Notes: If called without a data ref, an input BZZ object ref must be given and
--        the BZZ object must have been initialized by a previous call to Init()
function BZZ.Decode(...)
    -- Decode input stream
    local args = { ... }
    local self
    if type(args[1]) == 'table' and getmetatable(args[1]) == BZZ then
        self = table.remove(args, 1)
    else
        self = BZZ.new()
    end
    local dataPt = args[1]
    if dataPt then
        self:Init(dataPt, 1)
    else
        dataPt = self.DataPt
        if not dataPt then return nil end
    end
    -- Decode block size
    local n = 1
    local m = (1 << 24)
    while n < m do
        local b = self:decode_sub(0x8000 + (self.a >> 1))
        n = (n << 1) | b
    end
    self.size = n - m

    if self.size == 0 then return '' end
    if self.size > MAXBLOCK() * 1024 then return nil end
    -- Allocate
    if self.blocksize < self.size then
        self.blocksize = self.size
    end
    -- Decode Estimation Speed
    local fshift = 0
    if self:decode_sub(0x8000 + (self.a >> 1)) ~= 0 then
        fshift = fshift + 1
        if self:decode_sub(0x8000 + (self.a >> 1)) ~= 0 then fshift = fshift + 1 end
    end
    -- Prepare Quasi MTF
    local mtf = {}
    for k = 0, 255 do mtf[k] = k end
    local freq = {}
    for k = 0, FREQMAX() - 1 do freq[k] = 0 end
    local fadd = 4
    -- Decode
    local mtfno = 3
    local markerpos = -1
    local cx = self.ctx
    local dat = {}
    for i = 0, self.size - 1 do     -- byte:
        -- dummy loop avoids use of "goto" statement
        do                          -- dummy:
            local ctxid = CTXIDS() - 1
            if ctxid > mtfno then ctxid = mtfno end
            local cp = 0
            local imtf = 0
            while imtf < 2 do
                if self:decoder(cx, cp + ctxid) ~= 0 then
                    mtfno = imtf
                    dat[i] = mtf[mtfno]
                    -- (a "goto" here could give a segfault due to a Perl bug)
                    goto rotate -- do rotation
                end
                cp = cp + CTXIDS()
                imtf = imtf + 1
            end
            local bits = 1
            while bits < 8 do
                if self:decoder(cx, cp) ~= 0 then
                    local n2 = 1
                    local m2 = (1 << bits)
                    while n2 < m2 do
                        local b = self:decoder(cx, cp + n2)
                        n2 = (n2 << 1) | b
                    end
                    mtfno = imtf + n2 - m2
                    dat[i] = mtf[mtfno]
                    goto rotate -- do rotation
                end
                cp = cp + imtf
                bits = bits + 1
                imtf = imtf << 1
            end
            mtfno = 256
            dat[i] = 0
            markerpos = i
            goto nextByte   -- no rotation necessary
        end
        ::rotate::
        do
            -- Rotate mtf according to empirical frequencies (new!)
            -- Adjust frequencies for overflow
            fadd = fadd + (fadd >> fshift)
            if fadd > 0x10000000 then
                fadd = fadd >> 24
                for k = 0, FREQMAX() - 1 do freq[k] = freq[k] >> 24 end
            end
            -- Relocate new char according to new freq
            local fc = fadd
            if mtfno < FREQMAX() then fc = fc + freq[mtfno] end
            local k = mtfno
            while k >= FREQMAX() do
                mtf[k] = mtf[k - 1]
                k = k - 1
            end
            while k > 0 and fc >= freq[k - 1] do
                mtf[k] = mtf[k - 1]
                freq[k] = freq[k - 1]
                k = k - 1
            end
            mtf[k] = dat[i]
            freq[k] = fc
            -- when "goto" was used, Perl 5.8.6 could segfault here
            -- unless "next" was explicitly stated
        end
        ::nextByte::
    end
--
-- Reconstruct the string
--
    if markerpos < 1 or markerpos >= self.size then return nil end
    -- Allocate pointers
    -- Prepare count buffer
    local count = {}
    for c = 0, 255 do count[c] = 0 end
    local posn = {}
    -- Fill count buffer
    local i = 0
    while i < markerpos do
        local c = dat[i]
        posn[i] = (c << 24) | (count[c] & 0xffffff)
        count[c] = count[c] + 1
        i = i + 1
    end
    posn[i] = 0 -- (initialize marker entry just to be safe)
    i = i + 1
    while i < self.size do
        local c = dat[i]
        posn[i] = (c << 24) | (count[c] & 0xffffff)
        count[c] = count[c] + 1
        i = i + 1
    end
    -- Compute sorted char positions
    local last = 1
    for c = 0, 255 do
        local tmp = count[c]
        count[c] = last
        last = last + tmp
    end
    -- Undo the sort transform
    i = 0
    last = self.size - 1
    while last > 0 do
        local n3 = posn[i]
        local c = n3 >> 24
        last = last - 1
        dat[last] = c
        i = count[c] + (n3 & 0xffffff)
    end
    -- Final check and return decoded data
    if i ~= markerpos then return nil end
    dat[self.size - 1] = nil    -- (last byte isn't real)
    local bytes = {}
    for k = 0, self.size - 2 do bytes[k + 1] = string.char(dat[k]) end
    return table.concat(bytes)
end

--------------------------------------------------------------------------------
-- Inputs: 0) BZZ object ref, 1) ctx (Lua: context array and index)
-- Returns: decoded bit
function BZZ:decoder(cx, idx)
    local ctx = cx[idx]
    local z = self.a + self.p[ctx]
    if z <= self.fence then
        self.a = z
        return (ctx & 1)
    end
    -- must pass $_[1] so subroutine can modify value (darned C++ pass-by-reference!)
    return self:decode_sub(z, cx, idx)
end

--------------------------------------------------------------------------------
-- Inputs: 0) BZZ object ref, 1) z, 2) ctx (or undef) (Lua: array and index)
-- Returns: decoded bit
function BZZ:decode_sub(z, cx, idx)
    local ctx = cx and cx[idx]

    -- ensure that we have at least 16 bits of encoded data available
    if self.scount < 16 then
        -- preload byte by byte until we have at least 24 bits
        while self.scount <= 24 do
            if self.Pos < self.DataLen then
                self.byte = string.byte(self.DataPt, self.Pos + 1)
                self.Pos = self.Pos + 1
            else
                self.byte = 0xff
                self.delay = self.delay - 1
                if self.delay < 1 then
                    -- setting size to zero forces error return from Decode()
                    self.size = 0
                    return 0
                end
            end
            self.buffer = (self.buffer << 8) | self.byte
            self.scount = self.scount + 8
        end
    end
    -- Save bit
    local a = self.a
    local bit, code
    if ctx ~= nil then
        bit = (ctx & 1)
        -- Avoid interval reversion
        local d = 0x6000 + ((z + a) >> 2)
        if z > d then z = d end
    else
        bit = 0
    end
    -- Test MPS/LPS
    code = self.code
    if z > code then
        bit = bit ~ 1
        -- LPS branch
        z = 0x10000 - z
        a = a + z
        code = code + z
        -- LPS adaptation
        if ctx ~= nil then cx[idx] = self.dn[ctx] end
        -- LPS renormalization
        local sft = a >= 0xff00 and self.ffzt[a & 0xff] + 8 or self.ffzt[(a >> 8) & 0xff]
        self.scount = self.scount - sft
        self.a = (a << sft) & 0xffff
        code = ((code << sft) & 0xffff) | ((self.buffer >> self.scount) & ((1 << sft) - 1))
    else
        -- MPS adaptation
        if ctx ~= nil and a >= self.m[ctx] then cx[idx] = self.up[ctx] end
        -- MPS renormalization
        self.scount = self.scount - 1
        self.a = (z << 1) & 0xffff
        code = ((code << 1) & 0xffff) | ((self.buffer >> self.scount) & 1)
    end
    -- Adjust fence and save new code
    self.fence = code >= 0x8000 and 0x7fff or code
    self.code = code
    return bit
end

return BZZ
