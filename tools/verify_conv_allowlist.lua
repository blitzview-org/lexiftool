--------------------------------------------------------------------------------
-- File:         tools/verify_conv_allowlist.lua
--
-- Description:  conversion-shape findings that are a known, deliberate gap
--------------------------------------------------------------------------------

-- Entries here are reported by section 3e of tools/verify_port.lua
-- (conversion shapes) but do not fail the gate. Every entry needs a reason,
-- and the reason must be a scope statement ("this part is not ported"),
-- never "it doesn't work". An entry that no longer matches a finding fails
-- the gate as stale, so this list can only shrink.
--
-- Keyed exactly like the finding: 'Module.Table TagID[listIndex] Conv[N]',
-- plus ' missing' / ' extra' / ' values' / ' length' for hash keys, hash
-- values and list length.

return {
}
