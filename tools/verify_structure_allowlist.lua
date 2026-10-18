--------------------------------------------------------------------------------
-- File:         tools/verify_structure_allowlist.lua
--
-- Description:  structural-parity ratchet (see tools/verify_structure.lua)
--------------------------------------------------------------------------------

-- Modules listed here are still in remediation for RENAMED functions and are
-- report-only in `make verify`; every module NOT listed here must have no
-- renamed (case-mismatched) functions. MISSING functions (legitimate port
-- scope, documented in each module's Port notes) are always report-only.
-- Remove a module from this table once its function names match the Perl
-- original exactly.

return {
}
