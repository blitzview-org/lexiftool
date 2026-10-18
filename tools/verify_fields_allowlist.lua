--------------------------------------------------------------------------------
-- File:         tools/verify_fields_allowlist.lua
--
-- Description:  full-field-comparison findings that are known and not yet
--               fixed (the work list of section 3f of tools/verify_port.lua)
--------------------------------------------------------------------------------

-- Entries here are reported by section 3f of tools/verify_port.lua (full
-- field comparison of every tag info and table head against upstream) but
-- do not fail the gate. The list was seeded with every finding when the
-- full comparison was introduced; it is the work list for the table fixes,
-- not a list of accepted deviations. An entry that no longer matches a
-- finding fails the gate as stale, so this list can only shrink: fix the
-- table, then delete the entry (or regenerate the whole file, see below).
-- It is empty now: every finding fails the gate; keep it empty.
--
-- Keyed exactly like the finding:
--   'Module.Table TagID[listIndex] path what'
-- with TagID 'HEAD' for the table head, path the field key and its nested
-- keys joined by '.', what one of missing / extra / differs / shape.
-- The value is the finding's message at the time it was listed.
--
-- Regenerate (keeps this head comment, overwrites the entries; run with the
-- LUA_PATH/LUA_CPATH of `make verify`, e.g. by copying its command line):
--   lua5.4 tools/verify_port.lua --fields-allowlist tools/verify_fields_allowlist.lua

return {
}
