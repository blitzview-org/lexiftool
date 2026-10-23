--------------------------------------------------------------------------------
-- File:         lexiftool/Unknown.lua
-- Ported from:  lib/Image/ExifTool/Unknown.pm
--
-- Description:  Unknown EXIF maker notes tags
--
-- Revisions:    04/07/2004  - P. Harvey Created
--
-- Port notes:   read subset: the Main table with upstream's single 0x0e00
--               PrintIM fixture. Deferred: the WRITE_PROC/CHECK_PROC entries
--               (Exif::WriteExif / Exif::CheckExif) that make the table
--               writable.
--------------------------------------------------------------------------------

local Unknown = {}

-- Unknown maker notes
Unknown.Main = {
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    GROUPS = { [0] = 'MakerNotes', [1] = 'MakerUnknown', [2] = 'Camera' },

    -- this seems to be a common fixture, so look for it in unknown maker notes
    [0x0e00] = {
        Name = 'PrintIM',
        Description = 'Print Image Matching',
        SubDirectory = {
            TagTable = 'lexiftool.PrintIM.Main',
        },
    },
}

return Unknown
