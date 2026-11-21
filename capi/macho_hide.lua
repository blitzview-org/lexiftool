-- capi/macho_hide.lua OBJECT... - marks every global symbol a Mach-O object
-- file defines, except _lexiftool_*, as private external (in place), as
-- -fvisibility=hidden would have compiled it. A relocatable link (zig cc -r,
-- build-macos.sh) then turns these symbols into local ones, so that in the
-- embedded C API library only the lexiftool_* functions stay global: the
-- Mach-O counterpart of `objcopy --keep-global-symbol` (build-linux.sh),
-- for which there is no tool for Mach-O.
--
-- Handles 64-bit little-endian object files (x86_64, arm64): the symbol
-- table of LC_SYMTAB, entries nlist_64 { n_strx u32, n_type u8, n_sect u8,
-- n_desc u16, n_value u64 }. A symbol is changed when it is defined in a
-- section (n_type & N_TYPE == N_SECT), external (N_EXT), no debugging
-- entry (N_STAB bits clear) and not yet private external (N_PEXT).

local N_STAB, N_PEXT, N_TYPE, N_EXT, N_SECT = 0xe0, 0x10, 0x0e, 0x01, 0x0e
local MH_MAGIC_64, LC_SYMTAB = 0xfeedfacf, 0x2

local function hide(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("a")
    f:close()
    local magic, _, _, _, ncmds = string.unpack("<I4i4i4I4I4", data)
    assert(magic == MH_MAGIC_64, path .. ": not a 64-bit little-endian Mach-O file")
    local pos, changed = 33, 0     -- (load commands after the 32-byte header)
    local parts = {}
    for _ = 1, ncmds do
        local cmd, size = string.unpack("<I4I4", data, pos)
        if cmd == LC_SYMTAB then
            local symoff, nsyms, stroff = string.unpack("<I4I4I4", data, pos + 8)
            local out, last = {}, 1
            for i = 0, nsyms - 1 do
                local at = symoff + i * 16 + 1
                local strx, ntype = string.unpack("<I4B", data, at)
                local name = string.unpack("z", data, stroff + strx + 1)
                if ntype & N_STAB == 0 and ntype & N_TYPE == N_SECT and ntype & N_EXT ~= 0
                        and ntype & N_PEXT == 0 and not name:find("^_lexiftool_") then
                    out[#out + 1] = data:sub(last, at + 3)
                    out[#out + 1] = string.char(ntype | N_PEXT)
                    last = at + 5
                    changed = changed + 1
                end
            end
            out[#out + 1] = data:sub(last)
            parts = out
        end
        pos = pos + size
    end
    if changed > 0 then
        f = assert(io.open(path, "wb"))
        f:write(table.concat(parts))
        f:close()
    end
    return changed
end

local total = 0
for _, path in ipairs(arg) do total = total + hide(path) end
print(("macho_hide: %d symbols made private external in %d files"):format(total, #arg))
