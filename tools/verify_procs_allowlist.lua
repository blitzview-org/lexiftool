--------------------------------------------------------------------------------
-- File:         tools/verify_procs_allowlist.lua
--
-- Description:  tables whose missing *_PROC is a known, deliberate gap
--------------------------------------------------------------------------------

-- Entries here are reported by tools/verify_procs.lua but do not fail the
-- gate. Every entry needs a reason, and the reason must be a scope statement
-- ("this proc is not ported"), never "it doesn't work".
--
-- The four below share one shape: upstream uses the SAME function as both
-- PROCESS_PROC and WRITE_PROC, and this port has ported only its read half.
-- Hanging it on WRITE_PROC would advertise write support that isn't there --
-- WriteDirectory would call it and get a read-path return value back.
--
-- Keyed 'Module.Table PROC'.

return {
    ['FotoStation.Main WRITE_PROC']  = 'ProcessFotoStation: read half only, FotoStation write path deferred',
}
