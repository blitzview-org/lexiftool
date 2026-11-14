--------------------------------------------------------------------------------
-- File:         test/test_byteorder.lua
--
-- Description:  unit tests for the byte-order statics (SetByteOrder /
--               GetByteOrder) and the endian-aware primitive readers
--------------------------------------------------------------------------------

local lexiftool = require('lexiftool')
local TestLib = require('test.TestLib')
local is = TestLib.is

local MM = '\x01\x02\x03\x04\x05\x06'
local II = '\x02\x01\x04\x03\x06\x05'

lexiftool.SetByteOrder('MM')
is('MM', lexiftool.GetByteOrder(), 'GetByteOrder returns MM')
is(1, lexiftool.SetByteOrder('II'), 'SetByteOrder II accepted')
is('II', lexiftool.GetByteOrder(), 'GetByteOrder returns II')
is(false, lexiftool.SetByteOrder('bogus') and true or false, 'SetByteOrder rejects bogus')
is('II', lexiftool.GetByteOrder(), 'rejected SetByteOrder keeps state')

lexiftool.SetByteOrder('MM')
is(0x0102, lexiftool.Get16u(MM, 0), 'Get16u MM u16')
is(0x0304, lexiftool.Get16u(MM, 2), 'Get16u MM second u16')
is(0x01020304, lexiftool.Get32u(MM, 0), 'Get32u MM u32')
is(0x03040506, lexiftool.Get32u(MM, 2), 'Get32u MM second u32')
is(0x0201, lexiftool.Get16uRev(MM, 0), 'Get16uRev MM (reversed byte order)')
is(0x04030201, lexiftool.Get32uRev(MM, 0), 'Get32uRev MM (reversed byte order)')
is(258, lexiftool.Get16s(MM, 0), 'Get16s MM positive')
is(-2, lexiftool.Get16s('\xff\xfe', 0), 'Get16s MM negative')

lexiftool.SetByteOrder('II')
is(0x0102, lexiftool.Get16u(II, 0), 'Get16u II u16')
is(0x0304, lexiftool.Get16u(II, 2), 'Get16u II second u16')
is(0x03040102, lexiftool.Get32u(II, 0), 'Get32u II u32')
is(0x0201, lexiftool.Get16uRev(II, 0), 'Get16uRev II (reversed byte order)')
is(-2, lexiftool.Get16s('\xfe\xff', 0), 'Get16s II negative')

is(0x41, lexiftool.Get8u('A', 0), 'Get8u')
is(nil, lexiftool.Get8u('A', 1), 'Get8u out of range')
is(-1, lexiftool.Get8s('\xff', 0), 'Get8s')

is(nil, lexiftool.Get16u(MM, 5), 'Get16u offset 5 (out of range)')
is(nil, lexiftool.Get32u(MM, 5), 'Get32u offset 5 (out of range)')

is('1.23', lexiftool.RoundFloat(1.23456, 3), 'RoundFloat sig 3')
is('1.23e+03', lexiftool.RoundFloat(1234.56, 3), 'RoundFloat sig 3 integer scale')

-- restore default byte order for the rest of the run
lexiftool.SetByteOrder('MM')
is('MM', lexiftool.GetByteOrder(), 'byte order restored')

TestLib.done()