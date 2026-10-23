--------------------------------------------------------------------------------
-- File:         test/test_trailer.lua
--
-- Description:  Lua test for the JPEG trailer identification infrastructure
--               (ExifTool.IdentifyTrailer).  Feeds synthetic file tails to
--               the identifier and checks the recognized trailer types; no
--               standard output data is required.
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local raf = require('lexiftool.RandomAccess')
local TestLib = require('test.TestLib')
local ok = TestLib.ok
local done = TestLib.done

local et = lexiftool.new()

-- identify the trailer type of an in-memory file tail
local function identify(tail)
    local r = raf.new(tail)
    local info = lexiftool.IdentifyTrailer(et, r)
    return info and info.DirName or nil
end

-- upstream footers (lib/Image/ExifTool.pm IdentifyTrailer)
ok(identify('data\0\1AXS!' .. '\x00\x00\x00\x40\x00\x00\x00\x02') == 'AFCP',
   'AFCP footer (AXS!) identified')
ok(identify('AXS*' .. '\x00\x01\x00\x02\x00\x00\x00\x03') == 'AFCP',
   'AFCP footer (AXS*) identified')
ok(identify('\xa1\xb2\xc3\xd4') == 'FotoStation', 'FotoStation footer identified')
ok(identify('\x01\x02cbipcbbl') == 'PhotoMechanic', 'PhotoMechanic footer identified')
ok(identify('\0\0SEFT') == 'Samsung', 'Samsung SEFT footer identified')
ok(identify('\255\255\255\255\x1b\x2a\x39HWfu\x84\x93\xa2\xb1') == 'Vivo',
   'Vivo footer identified')
ok(identify('no trailer here') == nil, 'plain data not misidentified')

done() -- end
