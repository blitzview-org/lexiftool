--------------------------------------------------------------------------------
-- File:         test/test_pdf.lua
-- Ported from:  t/PDF.t
--
-- Description:  Lua port of PDF.t: extracts information from
--               t/images/PDF.pdf and compares against the vendored
--               standard output (t/PDF_2.out), plus the upstream test-3
--               standard-security RC4 decryption vector.
--               Tests 4-21 write, delete and revert PDF.pdf/PDF2.pdf
--               incrementally, test 22 deletes all tags; tests 23-26 run
--               the AES/AESV2/AESV3 vectors; own assertions cover the
--               Rev 6 hardened hash and the SHA-2 digests behind it.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local is = TestLib.is
local check = TestLib.check
local done = TestLib.done

local T_DIR = TestLib.T_DIR
local carray = require('carray')

-- pack('H*', ...) hex-string helper for the upstream test vectors
local function packH(s)
    return (s:gsub('..', function(cc) return string.char(tonumber(cc, 16)) end))
end

-- test 1: Load the module(s)
ok(lexiftool ~= nil and lexiftool.new ~= nil, 'module loaded')

local testname = 'PDF'

-- test 2: Extract information from PDF.pdf
do
    local exifTool = lexiftool.new()
    local info = exifTool:ImageInfo(T_DIR .. '/images/PDF.pdf')
    ok(check(exifTool, info, testname, 2), 'test 2 matches')
end

-- test 3: Test Standard PDF decryption (RC4; upstream CryptTest helper)
do
    local PDF = require('lexiftool.PDF')
    local exifTool = lexiftool.new()
    -- upstream's constructor pre-creates all object members (incl. VALUE);
    -- this port initializes them lazily in Init(), so do that explicitly
    -- before HandleTag is driven directly
    exifTool:Init()
    local cryptInfo = {
        Filter = '/Standard',
        P = -60,
        V = 1,
        R = 0,
        O = '<2055c756c72e1ad702608e8196acad447ad32d17cff583235f6dd15fed7dab67>',
        U = '<7150bd1da9d292af3627fca6a8dde1d696e25312041aed09059f9daee04353ae>',
        _id = packH('12116a1a124ae4cd8179e8978f6ac88b'),
        _ref = '4 0 R',
        _ciphertext = string.pack('>I4', 0x34a290d3),
        _plaintext = string.pack('>I4', 0x5924d335),
    }
    local err = PDF.DecryptInit(exifTool, cryptInfo, cryptInfo._id)
    if not err then
        local data = cryptInfo._ciphertext
        data = PDF.Crypt(data, cryptInfo._ref, nil)
        err = cryptInfo._error
        if not err and data ~= cryptInfo._plaintext then
            err = string.format('test 3 (decryption) returned wrong value: %s',
                (data:gsub('.', function(c) return string.format('%02x', c:byte()) end)))
        end
    end
    if err then print('  ' .. err) end
    ok(not err, 'test 3 decryption')
end

-- tests 4-21: Test writing, deleting and reverting two different files
do
    -- do a bunch of edits
    local edits = { {  -- (on file containing both PDF Info and XMP)
        {   -- test 4: write PDF and XMP information
            { 'PDF:Creator', 'me' },
            { 'XMP:Creator', 'you' },
            { 'AllDates',    '2:30', { Shift = -1 } },
        },{ -- test 5: delete all PDF
            { 'PDF:all' },
        },{ -- test 6: write some XMP
            { 'XMP:Author', 'them' },
        },{ -- test 7: create new PDF
            { 'PDF:Keywords',  'one' },
            { 'PDF:Keywords',  'two' },
            { 'AppleKeywords', 'three' },
            { 'AppleKeywords', 'four' },
        },{ -- test 8: delete all XMP
            { 'XMP:all' },
        },{ -- test 9: write some PDF
            { 'PDF:Keywords',  'another one', { AddValue = 1 } },
            { 'AppleKeywords', 'three',       { DelValue = 1 } },
        },{ -- test 10: create new XMP
            { 'XMP:Author', 'us' },
        },{ -- test 11: write some PDF
            { 'PDF:Keywords',  'two',  { DelValue = 1 } },
            { 'AppleKeywords', 'five', { AddValue = 1 } },
        },{ -- test 12: delete re-added XMP
            { 'XMP:all' },
        },
    },{             -- (on file without PDF Info or XMP)
        {   -- test 14: create new XMP
            { 'XMP:Author', 'him' },
        },{ -- test 15: create new PDF
            { 'PDF:Author', 'her' },
        },{ -- test 16: delete XMP and PDF
            { 'XMP:all' },
            { 'PDF:all' },
        },{ -- test 17: delete XMP and PDF again
            { 'XMP:all' },
            { 'PDF:all' },
        },{ -- test 18: create new PDF
            { 'PDF:Author', 'it' },
        },{ -- test 19: create new XMP
            { 'XMP:Author', 'thing' },
        },{ -- test 20: delete all
            { 'all' },
        },
    } }
    local testnum = 3
    for testSet = 0, 1 do
        local testfile2, lastOK
        local testfile = T_DIR .. '/images/' .. (testSet ~= 0 and 'PDF2.pdf' or 'PDF.pdf')
        local testfile1 = testfile
        local exifTool = lexiftool.new()
        exifTool:Options('PrintConv', 0)
        for _, edit in ipairs(edits[testSet + 1]) do
            testnum = testnum + 1
            exifTool:SetNewValue()
            for _, e in ipairs(edit) do exifTool:SetNewValue(e[1], e[2], e[3]) end
            testfile2 = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.pdf'
            os.remove(testfile2)
            exifTool:WriteInfo(testfile1, testfile2)
            local info = exifTool:ImageInfo(testfile2,
                    'Filesize', 'PDF:all', 'XMP:Creator', 'XMP:Author', 'AllDates')
            local okk = check(exifTool, info, testname, testnum)
            ok(okk, 'test ' .. testnum .. ' matches')
            -- erase source file if previous test was OK
            if lastOK then os.remove(testfile1) end
            lastOK = okk
            testfile1 = testfile2    -- use this file for the next test
        end
        -- revert all edits and compare with original file
        testnum = testnum + 1
        exifTool:SetNewValue('PDF-update:all')
        testfile2 = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.pdf'
        os.remove(testfile2)
        exifTool:WriteInfo(testfile1, testfile2)
        if TestLib.binaryCompare(testfile2, testfile) == 1 then
            os.remove(testfile2)
            ok(true, 'test ' .. testnum .. ' revert matches original')
        else
            ok(false, 'test ' .. testnum .. ' revert matches original')
        end
        if lastOK then os.remove(testfile1) end
    end
end

-- test 22: Delete all tags
do
    local testnum = 22
    local exifTool = lexiftool.new()
    local testfile = TestLib.TEST_DIR .. '/' .. testname .. '_' .. testnum .. '_failed.pdf'
    os.remove(testfile)
    exifTool:Options('IgnoreMinorErrors', 1)
    exifTool:SetNewValue('all', nil)
    local okw = TestLib.writeInfo(exifTool, T_DIR .. '/images/PDF.pdf', testfile)
    exifTool:Options('IgnoreMinorErrors', 0)
    local info = exifTool:ImageInfo(testfile, 'pdf:all', 'xmp:all', { Duplicates = 1, Unknown = 1 })
    if okw and check(exifTool, info, testname, testnum) then
        os.remove(testfile)
        ok(true, 'test 22 matches')
    else
        ok(false, 'test 22 matches')
    end
end

-- test 23: Test AES decryption alone (tests 24-26 require Digest::MD5 or Digest::SHA)
do
    local AES = require('lexiftool.AES')
    local data = { value = carray.new('char'):append(packH('6fdc3ca684348bc8f31379aa46455d7b' ..
        '60c0989e027c1d82e746f136d6e95b74' ..
        '85735793ff64310e5b9e367dcc26f564')) }
    local err = AES.Crypt(data, '11223344556677889900112233445566')
    if err then
        print('  ' .. err)
        ok(false, 'test 23 AES decryption')
    elseif data.value:tostring() ~= 'ExifTool AES Test' then
        local hex = (data.value:tostring():gsub('.', function(c) return string.format('%02x', c:byte()) end))
        print('  Incorrect result from AES decryption: ' .. hex)
        ok(false, 'test 23 AES decryption')
    else
        ok(true, 'test 23 AES decryption')
    end
end

-- AES encryption in place (own assertions: t/PDF.t runs the decryption
-- direction only): with a given IV the buffer becomes the IV followed by the
-- padded ciphertext and decrypts back to the plain text; with a random IV
-- (perl.srand/perl.rand) the round trip holds as well
do
    local AES = require('lexiftool.AES')
    local key = '11223344556677889900112233445566'
    local iv = packH('000102030405060708090a0b0c0d0e0f')
    local plain = 'ExifTool AES Test'
    local data = { value = carray.new('char'):append(plain) }
    local err = AES.Crypt(data, key, iv)
    is(nil, err, 'AES encryption with a given IV')
    local enc = data.value:tostring()
    is(48, #enc, 'AES encryption: IV and two padded blocks')
    is(iv, enc:sub(1, 16), 'AES encryption: the buffer starts with the IV')
    err = AES.Crypt(data, key)
    is(nil, err, 'AES decryption of the encrypted buffer')
    is(plain, data.value:tostring(), 'AES round trip with a given IV')
    data = { value = carray.new('char'):append(plain) }
    err = AES.Crypt(data, key, 1)
    is(nil, err, 'AES encryption with a random IV')
    is(48, data.value:len(), 'AES encryption with a random IV: IV and two padded blocks')
    err = AES.Crypt(data, key)
    is(plain, err == nil and data.value:tostring(), 'AES round trip with a random IV')
    data = { value = carray.new('char'):append(plain) }
    is('Invalid AES key length (5)', AES.Crypt(data, '12345', 1), 'AES invalid key length')
    is(plain, data.value:tostring(), 'AES invalid key length leaves the data alone')
end

-- The layer over cipher.aes and cipher.rc4 (own assertions): the chaining
-- state Crypt leaves is the one Cipher continues (GetHash relies on it),
-- Cipher takes several blocks at once, noPad keeps the data unpadded, a bad
-- pad byte is reported as upstream, and an RC4Init stream carries on with
-- its keystream from one RC4Crypt call to the next
do
    local AES = require('lexiftool.AES')
    local key = '11223344556677889900112233445566'
    local iv = packH('000102030405060708090a0b0c0d0e0f')
    local plain = ('0123456789abcdef'):rep(3)
    local data = { value = carray.new('char'):append(plain) }
    is(nil, AES.Crypt(data, key, iv, 1), 'AES encryption without padding')
    local enc = data.value:tostring()
    is(16 + 48, #enc, 'AES noPad: no padding block for whole blocks')
    local x = { value = carray.new('char') }
    is(nil, AES.Crypt(x, key, iv, 1), 'AES encryption of empty data sets the IV')
    is(iv, x.value:tostring(), 'AES encryption of empty data gives the IV alone')
    local c1 = AES.Cipher(plain:sub(1, 16))
    local c2 = AES.Cipher(plain:sub(17))
    is(enc:sub(17), c1 .. c2, 'AES.Cipher continues the CBC chain of Crypt, one or more blocks')
    data = { value = carray.new('char'):append(enc) }
    is(nil, AES.Crypt(data, key, nil, 1), 'AES decryption without padding')
    is(plain, data.value:tostring(), 'AES noPad round trip')
    data = { value = carray.new('char'):append(enc) }
    is('AES decryption error (invalid pad byte)', AES.Crypt(data, key),
       'AES decryption reports an invalid pad byte')
    is('Invalid AES ciphertext length',
       AES.Crypt({ value = carray.new('char'):append('x') }, key), 'AES invalid ciphertext length')
    local short = { value = carray.new('char'):append(iv) }
    is(nil, AES.Crypt(short, key), 'AES decryption of the IV alone')
    is('', short.value:tostring(), 'AES decryption of the IV alone gives empty text')

    local PDF = require('lexiftool.PDF')
    -- (the well-known RC4 test vector: key "Key", plaintext "Plaintext")
    is(packH('bbf316e8d940af0ad3'), PDF.RC4Crypt('Plaintext', 'Key'), 'RC4 test vector')
    is('Plaintext', PDF.RC4Crypt(PDF.RC4Crypt('Plaintext', 'Key'), 'Key'), 'RC4 is symmetric')
    local st = PDF.RC4Init('Key')
    is(packH('bbf316e8d940af0ad3'), PDF.RC4Crypt('Plain', st) .. PDF.RC4Crypt('text', st),
       'RC4 key state carries on between calls')
end

-- tests 24-26: Test AESV2/AESV3 decryption via DecryptInit + Crypt
do
    local PDF = require('lexiftool.PDF')
    -- upstream CryptTest helper (decrypt mode; encrypt mode never used by
    -- the vendored tests)
    local function cryptTest(exifTool, info)
        local err = PDF.DecryptInit(exifTool, info, info._id)
        if not err then
            local data = info._ciphertext
            data = PDF.Crypt(data, info._ref or '1 0 R', nil)
            err = info._error
            if not err and data ~= info._plaintext then
                err = string.format('decryption returned wrong value: %s',
                    (tostring(data):gsub('.', function(c) return string.format('%02x', c:byte()) end)))
            end
        end
        return err
    end

    local exifTool = lexiftool.new()
    exifTool:Init()

    -- test 24: AESV2 without password
    do
        local info = {
            Filter = '/Standard',
            V = 4,
            R = 4,
            P = -1340,
            Length = 128,
            StmF = '/StdCF',
            StrF = '/StdCF',
            CF = {
                StdCF = {
                    AuthEvent = '/DocOpen',
                    CFM = '/AESV2',
                    Length = 16,
                },
            },
            EncryptMetadata = 'false',
            O = '<181ee8e93a99fa1c2a534dd68a5ab07c54268cfe8fbf28c468316b6f732674c1>',
            U = '<a3525aef4143f4419c78b109317f0e5200000000000000000000000000000000>',
            _ref = '4 0 R',
            _id = packH('d0a736f05faf64c6b52dea82a2ad53e0'),
            _plaintext = 'This was a test',
            _ciphertext = packH('a86b5e00d9c7e4455cf5d8cedf195c2060e1467ea6d698876a77e9a66cb7867c'),
        }
        local err = cryptTest(exifTool, info)
        if err then print('  ' .. err) end
        ok(not err, 'test 24 AESV2 decryption')
    end

    -- test 25: AESV3 without password
    do
        local info = {
            Filter = '/Standard',
            V = 5,
            R = 5,
            P = -1028,
            Length = 256,
            StmF = '/StdCF',
            StrF = '/StdCF',
            CF = {
                StdCF = {
                    AuthEvent = '/DocOpen',
                    CFM = '/AESV3',
                    Length = 32,
                },
            },
            Perms = '<014ee28fe2b91e2198a593b7c3b22f50>',
            O = '<83e5edfcdecbe2ebe6d519dbafe80fd453028dda119eb76d0216e1344392320d60e1467ea6d698876a77e9a66cb7867c>',
            U = '<e5e7ade8aebdc9413a0fd176efc4081bdbad3b16a67ece7a01fadb24010a003ea86b5e00d9c7e4455cf5d8cedf195c20>',
            OE = '<a29f37f1f085b575d9016daad05ca466dd073ba5d067cc7ffa8ef7d1605e460e>',
            UE = '<47ea891b25af77aaceccf8f2fdeff0c09e9d0f67275f059dbfabbb18fcbf848d>',
            _ref = 'dummy',
            _id = packH('618cb5be1d82fceea9a501b62d408296'),
            _plaintext = 'This was a test',
            _ciphertext = packH('e90756e8fd60fb7390c34d931e3e3d61898cd133e613e8cf86cd40f7b207a62d'),
        }
        local err = cryptTest(exifTool, info)
        if err then print('  ' .. err) end
        ok(not err, 'test 25 AESV3 decryption')
    end

    -- test 26: AESV3 with a password
    do
        local info = {
            Filter = '/Standard',
            V = 5,
            R = 5,
            P = -1028,
            Length = 256,
            StmF = '/StdCF',
            StrF = '/StdCF',
            CF = {
                StdCF = {
                    AuthEvent = '/DocOpen',
                    CFM = '/AESV3',
                    Length = 32,
                },
            },
            Perms = '<014ee28fe2b91e2198a593b7c3b22f50>',
            O = '<31eefe924a298d8bf19eafc9be6abdfa65a97478f94e907dccff5ac000b83fa521167b86cf70bf77d4a054bc9a59573d>',
            U = '<6525a788c2ebf27baa45f526bcdb9d2f96c3c67ae1c62324135cac0b823451ba9ad8edb68d167d2d8370d799c41d17d7>',
            OE = '<ea58e3c731999cdc0f8a395c7391836c2b2db0b4ac86439b3fe5692ddc71671a>',
            UE = '<f6818f43e176dfe8912f62717032169cf48854f540f7b7641be363ef50371f07>',
            _password = 'ExifTool',
            _ref = 'dummy',
            _id = packH('b5f9d17b07152a45bc0a939727c389ad'),
            _plaintext = 'This was a test',
            _ciphertext = packH('8bb3565d8c4b9df8cc350954d9f91a46aa47e40eeb5a0cff559acd5ec3e94244'),
        }
        exifTool:Options('Password', info._password)
        local err = cryptTest(exifTool, info)
        if err then print('  ' .. err) end
        ok(not err, 'test 26 AESV3 decryption')
    end
end

-- Rev 6 hardened hash (own assertion; upstream's AESV3 vectors are Rev 5,
-- so GetHash's Rev 6 branch has no golden in t/PDF.t -- the expected values
-- come from upstream's own Image::ExifTool::PDF::GetHash with Digest::SHA)
do
    local PDF = require('lexiftool.PDF')
    local function hexOf(s) return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
    local h1 = PDF.GetHash('', 'saltsalt', ('v'):rep(48), 6)
    local h2 = PDF.GetHash('ExifTool', 'saltsalt', ('v'):rep(48), 6)
    ok(hexOf(h1) == 'fc154c9d35d84f6dc46af1b56ba2926acfa070ebc10979d73ab3cdea3a3682bd' and
       hexOf(h2) == '5d951ed47c4bfa38f58af54fa55c336bf3063d2d36e3b33ead8429d346f0f66a',
       'Rev 6 hardened hash')
end

-- SHA-2 digests behind GetHash (own assertions; ExifTool.sha256/sha384/
-- sha512 and DigestSHA stand for Digest::SHA). Expected values are the
-- FIPS 180-4 example digests of '' and 'abc'.
do
    local function hexOf(s) return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
    local vectors = {
        { 256, lexiftool.sha256, '',
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' },
        { 256, lexiftool.sha256, 'abc',
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' },
        { 384, lexiftool.sha384, '',
          '38b060a751ac96384cd9327eb1b1e36a21fdb71114be07434c0cc7bf63f6e1da' ..
          '274edebfe76f65fbd51ad2f14898b95b' },
        { 384, lexiftool.sha384, 'abc',
          'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed' ..
          '8086072ba1e7cc2358baeca134c825a7' },
        { 512, lexiftool.sha512, '',
          'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce' ..
          '47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e' },
        { 512, lexiftool.sha512, 'abc',
          'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a' ..
          '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f' },
    }
    for _, v in ipairs(vectors) do
        local alg, func, data, expected = v[1], v[2], v[3], v[4]
        local got = hexOf(func(nil, data))
        ok(got == expected, ('SHA-%d of %q: %s'):format(alg, data, got))
    end
    ok(hexOf(lexiftool.sha256(nil, carray.new('uint8'):append('abc'))) ==
       'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
       'SHA-256 of a byte carray')

    -- incremental Digest::SHA object: pieces == one-shot, digest() resets
    local msg = ('0123456789abcdef'):rep(20) -- 320 bytes, several blocks
    for _, alg in ipairs({ 256, 384, 512 }) do
        local func = ({ [256] = lexiftool.sha256, [384] = lexiftool.sha384, [512] = lexiftool.sha512 })[alg]
        local digest = lexiftool.DigestSHA(alg)
        digest:add(msg:sub(1, 1))
        digest:add(msg:sub(2, 100))
        digest:add(msg:sub(101))
        ok(digest:digest() == func(nil, msg), 'DigestSHA(' .. alg .. ') add in pieces == one-shot')
        digest:add('abc')
        ok(digest:digest() == func(nil, 'abc'), 'DigestSHA(' .. alg .. ') digest() resets the object')
    end
end

done() -- end
