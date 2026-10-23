max_line_length = 160

-- The Lang tables are machine-generated (tools/gen_lang.pl) and mirror the
-- vendored Lang/*.pm line for line; a handful of translation strings are
-- longer than the column limit there, and wrapping them would break exactly
-- the correspondence the generator exists to keep.
files['src/lexiftool/Lang/*.lua'] = {
    max_line_length = false,
}

-- Sony.pm's tag tables are translated line for line, and many upstream lines
-- (model-list Conditions, the packed AF-point grids, the cipher tables,
-- reference comments) are already longer than the column limit there; the
-- Lua spelling of a Condition is longer still.  Wrapping them would break the
-- line correspondence with the Perl original.
files['src/lexiftool/Sony.lua'] = {
    max_line_length = false,
}

-- FujiFilm.pm likewise: the M-RAW tag lines and the InternalSerialNumber
-- conversions are one upstream line each, longer than the limit in Lua.
files['src/lexiftool/FujiFilm.lua'] = {
    max_line_length = false,
}

-- DICOM.pm's %Main and %uid contain a handful of duplicate keys (e.g. the two
-- '0021,1018' GEMS_ACQU_01 entries, and '1.2.840.10008.5.1.4.1.1.66' in %uid).
-- Perl keeps the last assignment, and so does a Lua table constructor -- the
-- semantics match, so the duplicates are carried verbatim rather than silently
-- de-duplicated, which would make the port diverge from the upstream listing.
files['src/lexiftool/DICOM.lua'] = {
    ignore = { '314' }, -- value assigned to field ... is overwritten
}

-- Nikon.pm likewise: the AFInfo2/ColorBalance/MenuSettings tables carry
-- upstream lines (Conditions, reference comments, packed entries) that are
-- already longer than the limit there.
files['src/lexiftool/Nikon.lua'] = {
    max_line_length = false,
}

-- Canon.pm likewise: model-list Conditions and reference comments are longer
-- than the limit already upstream, and CameraInfo650D's FileIndex repeats its
-- `Format => 'int32u'` key (Perl keeps the last one, as does Lua).
files['src/lexiftool/Canon.lua'] = {
    max_line_length = false,
    ignore = { '314' }, -- value assigned to field ... is overwritten
}

-- Casio.pm: one upstream reference comment (a search URL) is longer than the
-- limit already there.
files['src/lexiftool/Casio.lua'] = {
    max_line_length = false,
}

-- PanasonicRaw.pm's %jpgFromRawMap repeats its `MakerNotes => 'ExifIFD'`
-- key (Perl keeps the last one, as does Lua).
files['src/lexiftool/PanasonicRaw.lua'] = {
    ignore = { '314' }, -- value assigned to field ... is overwritten
}

-- QuickTime.pm likewise: the ftyp lookup, the Nextbase and Keys tables carry
-- duplicate keys upstream ('3gp6', 'Wi-Fi SSID' ...; Perl keeps the last one,
-- as does Lua), several upstream lines are longer than the limit, and the
-- ported subs keep upstream's trailing position updates (`$pos` after the
-- last GetString, `$val` after the last field of LocationInformation), and
-- keep upstream's variable names `$str`/`$num`, which shadow the facade
-- aliases str/num inside those conversions.
files['src/lexiftool/QuickTime.lua'] = {
    max_line_length = false,
    ignore = { '314', '311', '431' },
}

-- QuickTimeStream.pl's tag table lines and its NMEA/freeGPS regexes are one
-- upstream line each and already longer than the limit there; in Lua they are
-- longer still, and splitting a regex literal would turn it into a runtime
-- concatenation.
files['src/lexiftool/QuickTimeStream.lua'] = {
    max_line_length = false,
}

-- The exiftool script (main.lua) keeps upstream's ~155 file-scope variables
-- and 55 subs under their own names in a private environment (`local _ENV`,
-- see its Port notes) -- Lua allows only 200 locals per function.  Its
-- "globals" are fields of that environment, defined at the top level.
-- Unused variables named with a leading underscore stand for captures and
-- values upstream discards (Perl's `$1` that is never read).
files['src/lexiftool/main.lua'] = {
    allow_defined_top = true,
    max_line_length = 200,
    ignore = { '211/_.+', '212/_.+', '213/_.+', '231/_.+' },
}
