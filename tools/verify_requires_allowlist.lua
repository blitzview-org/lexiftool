--------------------------------------------------------------------------------
-- File:         tools/verify_requires_allowlist.lua
--
-- Description:  eager-require ratchet (see tools/verify_structure.lua)
--------------------------------------------------------------------------------

-- A top-level `local X = require('lexiftool.X')` in a ported module mirrors
-- upstream's `use Image::ExifTool::X;` -- and only that.  Where upstream has no
-- such `use`, the module is loaded LAZILY there (inside the function, or via a
-- call-time wrapper for a PROCESS_PROC/WRITE_PROC), because
-- `ExifTool:BuildCompositeTags` derives its worklist from `package.loaded`: a
-- module loaded eagerly contributes its Composite table to *every* file and can
-- reorder same-named Require/Desire tags.
--
-- Everything left here is a require whose TARGET HAS NO COMPOSITE TABLE, so it
-- cannot reach BuildCompositeTags' worklist at all -- checked against the
-- `compTables` list in lexiftool.lua, not assumed.  `Exif` is listed for the
-- same reason from the other direction: BuildCompositeTags includes
-- Exif.Composite unconditionally ("the foundational table"), so whether
-- Exif.lua happens to be loaded makes no difference.
--
-- It is still a ratchet: do not add entries.  A new one means either a target
-- that does carry a Composite table (a real bug), or a new no-Composite module
-- (then extend this list together with its justification).
--
-- Format: ['<Module>'] = { <Required>, ... }

return {
    -- Exif: always in the Composite worklist regardless of package.loaded
    HP            = { 'Exif' },
    KyoceraRaw    = { 'Exif' },
    Lytro         = { 'Exif' },
    NikonCustom   = { 'Exif' },
    NikonSettings = { 'Exif' },
    Parrot        = { 'Exif' },

    -- targets without a Composite table of their own
    DjVu          = { 'BZZ' },
    HtmlDump      = { 'HTML' },
    Nikon         = { 'NikonCustom' },
    PLIST         = { 'ASF' },
    XMP           = { 'JPEG' },
}
