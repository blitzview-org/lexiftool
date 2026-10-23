--------------------------------------------------------------------------------
-- File:         lexiftool/Motorola.lua
-- Ported from:  lib/Image/ExifTool/Motorola.pm
--
-- Description:  Read Motorola meta information
--
-- Revisions:    2015/10/29 - P. Harvey Created
--
-- References:   1) Neal Krawetz private communication
--
-- Port notes:   `Main` ported in full -- only 5 real tags are defined
--               upstream (`BuildNumber`/`SerialNumber`/`CustomRendered`/
--               `DriveMode`/`Sensor`/`ManufactureDate`), everything else in
--               the table is a commented-out placeholder too. `Motorola.t`'s
--               own test runs with `Unknown => 1`, so the many undefined
--               maker-note entries show up via the generic unknown-numeric-
--               tag fallback (`Motorola_0xNNNN`), no tag table entry needed
--               for them.
--------------------------------------------------------------------------------

local Motorola = {}

Motorola.Main = {
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    WRITABLE = 1,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    -- 0x54e0 - int8u: 1
    -- 0x54f0 - float
    [0x5500] = { Name = 'BuildNumber', Writable = 'string' }, -- (eg. 'MPJ24.139-23.4')
    [0x5501] = { Name = 'SerialNumber', Writable = 'string' }, -- (eg. 'ZY2238TJ4V')
    [0x6420] = {
        Condition = function(_self, _val, format) return format == 'string' end,
        Name = 'CustomRendered',
        Writable = 'string',
    },
    [0x64d0] = { Name = 'DriveMode', Writable = 'string' },
    [0x665e] = { Name = 'Sensor', Writable = 'string' }, -- (eg. 'BACK,IMX230')
    [0x6705] = { Name = 'ManufactureDate', Writable = 'string' }, -- (NC, eg. '03Jun2015')
}

return Motorola
