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
-- Port notes:   The cipher itself is computed by the rock cipher.aes; this
--               module is a thin layer that keeps upstream's entry points
--               and their semantics, so that the callers in PDF.lua read
--               like the Perl original.  Upstream's pure-Perl AES (the
--               sbox/rsbox/rcon tables and the round functions AddRoundKey,
--               SubBytes, ShiftRows, MixColumns, xtime, Mult and their
--               inverses) is not ported line for line (doc/differences.md).
--               - KeyExpansion keeps the expanded key as a cipher.aes key
--                 object; the CBC chaining bytes are kept as a 16-byte
--                 string.  Cipher and InvCipher en/decrypt with that key and
--                 chaining state and take one or more whole 16-byte blocks
--                 (upstream: exactly one), so PDF.lua can cipher a run of
--                 blocks in one call.
--               - Crypt's data reference (`\$dat`) is a box
--                 `{ value = <carray> }` that it encrypts or decrypts in
--                 place, returning only an error string, as upstream.  It
--                 adds and removes the padding itself, as upstream does
--                 (cipher.aes runs CBC without padding): no padding check
--                 beyond upstream's pad byte test, and the noPad flag as
--                 upstream.  The chaining state after Crypt is the one
--                 upstream leaves, for Cipher calls that continue it.
--               - The random IV comes from perl.srand/perl.rand (Perl's
--                 drand48), seeded from time() and the process id ($$,
--                 perl.pid) as upstream does, so the same random state
--                 gives the same IV bytes.
--------------------------------------------------------------------------------

local perl = require('lexiftool.perl')
local carray = require('carray')
local aes = require('cipher.aes')
local substr = perl.substr
local length = perl.length
local truthy = perl.truthy
local pack = perl.pack
local ord = perl.ord
local chr = perl.chr
local int = perl.int
local rand = perl.rand
local srand = perl.srand
local time = perl.time
local pid = perl.pid    -- (Perl's $$)
local srep = string.rep
local tunpack = table.unpack

local AES = {}

local seeded -- flag set if we already seeded random number generator
local cbc    -- cipher-block chaining bytes (16-byte string)

-- (upstream's round keys: the key object of cipher.aes)
local RoundKey

-- the last 16 bytes of a string or carray (the next CBC chaining bytes)
local function lastBlock(dat)
    if type(dat) == 'string' then return dat:sub(-16) end
    local n = dat:len()
    return dat:tostring(n - 15, n)
end

--------------------------------------------------------------------------------
-- This function produces 4*($nr+1) round keys.
-- The round keys are used in each round to encrypt the states.
-- Inputs: 0) key string (must be 16, 24 or 32 bytes long)
function AES.KeyExpansion(key)
    RoundKey = aes.newkey(key)
end

--------------------------------------------------------------------------------
-- Encrypt (Cipher) or decrypt (InvCipher) a block of data with CBC
-- Inputs: 0) string to cipher (must be 16 bytes long)
-- Returns: cipher'd string
-- (Lua: any multiple of 16 bytes, chained as consecutive blocks)
function AES.Cipher(input)
    local out = aes.encrypt(input, RoundKey, { iv = cbc, padding = 'none' })
    if #out > 0 then cbc = lastBlock(out) end -- save for CBC
    return out -- return packed ciphertext
end

function AES.InvCipher(input)
    local out = aes.decrypt(input, RoundKey, { iv = cbc, padding = 'none' })
    if length(input) > 0 then cbc = lastBlock(input) end -- update CBC for next block
    return out -- return packed plaintext
end

--------------------------------------------------------------------------------
-- Encrypt/Decrypt using AES-CBC algorithm (with fixed 16-byte blocks)
-- Inputs: 0) data reference (with leading 16-byte initialization vector when decrypting)
--         1) encryption key (16, 24 or 32 bytes for AES-128, AES-192 or AES-256)
--         2) encrypt flag (false for decryption, true with length 16 bytes to
--            encrypt using this as the CBC IV, or true with other length to
--            encrypt with a randomly-generated IV)
--         3) flag to disable padding
-- Returns: error string, or undef on success
-- Notes: encrypts/decrypts data in place (encrypted data returned with leading IV)
-- (Lua: the data reference is a box `{ value = <carray> }`)
function AES.Crypt(dataPt, key, encrypt, noPad)

    -- validate key length
    local keyLen = length(key)
    if not (keyLen == 16 or keyLen == 24 or keyLen == 32) then
        return 'Invalid AES key length (' .. keyLen .. ')'
    end
    local partLen = length(dataPt.value) % 16
    if truthy(encrypt) then
        if length(encrypt) == 16 then
            cbc = encrypt
        else
            -- generate a random 16-byte CBC initialization vector
            if not seeded then
                srand(time() & (pid() + (pid() << 15)))
                seeded = 1
            end
            local cbc_ = {}
            for i = 0, 15 do
                cbc_[i] = int(rand(256))
            end
            encrypt = pack('C*', tunpack(cbc_, 0, 15))
            cbc = encrypt
        end
        -- add required padding so we can recover the
        -- original string length after decryption
        -- (padding bytes have value set to padding length)
        local padLen = 16 - partLen
        local plain = carray.new('char'):append(dataPt.value)
        if not (padLen == 16 and truthy(noPad)) then plain:append(srep(chr(padLen), padLen)) end
        -- the KeyExpansion routine must be called before encryption
        AES.KeyExpansion(key)
        -- encrypt all blocks behind the IV, which leads the data
        local out = carray.new('char'):append(encrypt) -- add IV to the start of the data
        aes.encrypt(plain, RoundKey, { iv = cbc, padding = 'none' }, out)
        cbc = lastBlock(out)
        dataPt.value = out
        return nil
    elseif partLen ~= 0 then
        return 'Invalid AES ciphertext length'
    elseif length(dataPt.value) >= 32 then
        -- take the CBC initialization vector from the start of the data
        cbc = substr(dataPt.value, 0, 16)
        substr(dataPt.value, 0, 16, '')
    else
        dataPt.value = carray.new('char')  -- empty text
        return nil
    end
    -- the KeyExpansion routine must be called before encryption
    AES.KeyExpansion(key)

    -- decrypt all blocks at once
    local out = aes.decrypt(dataPt.value, RoundKey, { iv = cbc, padding = 'none' }, carray.new('char'))
    cbc = lastBlock(dataPt.value)
    dataPt.value = out
    local dataLen = length(dataPt.value)
    if not truthy(noPad) then
        -- remove padding if necessary (padding byte value gives length of padding)
        local padLen = ord(substr(dataPt.value, -1, 1))
        if padLen > 16 then return 'AES decryption error (invalid pad byte)' end
        substr(dataPt.value, dataLen - padLen, padLen, '')
    end
    return nil
end

return AES
