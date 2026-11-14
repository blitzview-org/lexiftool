--------------------------------------------------------------------------------
-- File:         lexiftool/GE.lua
-- Ported from:  lib/Image/ExifTool/GE.pm
--
-- Description:  General Imaging maker notes tags
--
-- Revisions:    2010-12-14 - P. Harvey Created
--
-- Port notes:   ported in full -- GE.pm's `Main` table is tiny (three real
--               tags: `Macro`/`GEModel`/`GEMake`; everything else is a
--               commented-out placeholder upstream too). `GE.t`'s own test
--               runs with `Unknown => 1`, so the remaining maker-note
--               entries (0x0104/0x0203-0x0206/0x0500/0x0600) show up via the
--               generic unknown-numeric-tag fallback (`GE_0xNNNN`), no tag
--               table entry needed for them.
--------------------------------------------------------------------------------

local GE = {}

GE.Main = {
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    WRITABLE = 1,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = [[
        This table lists tags found in the maker notes of some General Imaging
        camera models.
    ]],
    [0x0202] = {
        Name = 'Macro',
        Writable = 'int16u',
        PrintConv = { [0] = 'Off', [1] = 'On' },
    },
    [0x0207] = {
        Name = 'GEModel',
        Format = 'string',
    },
    [0x0300] = {
        Name = 'GEMake',
        Format = 'string',
    },
}

return GE
