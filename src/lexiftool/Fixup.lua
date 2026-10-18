--------------------------------------------------------------------------------
-- File:         lexiftool/Fixup.lua
-- Ported from:  lib/Image/ExifTool/Fixup.pm
--
-- Description:  Utility to handle pointer fixups
--
-- Revisions:    01/19/2005 - P. Harvey Created
--               04/11/2005 - P. Harvey Allow fixups to be tagged with a marker,
--                            and add new marker-related routines
--               06/21/2006 - P. Harvey Patch to work with negative offsets
--               07/07/2006 - P. Harvey Added support for 16-bit pointers
--               02/19/2013 - P. Harvey Added IsEmpty()
--
-- Data Members:
--
--   Start     - Position in data where a zero pointer points to.
--   Shift     - Amount to shift offsets (relative to Start).
--   Fixups    - List of Fixup object references to to shift relative to this Fixup.
--   Pointers  - Hash of references to fixup pointer arrays, keyed by ByteOrder
--               string (with "2" added if pointer is 16-bit [default is 32-bit],
--               plus "_$marker" suffix if tagged with a marker name).
--
-- Procedure:
--
--            1. Create a Fixup object for each data block containing pointers
--            2. Call AddFixup with the offset of each pointer in the block
--               - pointer is assumed int32u with the current byte order
--               - may also be called with a fixup reference for contained blocks
--            3. Add the necessary pointer offset to $$fixup{Shift}
--            4. Add data size to $$fixup{Start} if data is added before the block
--               - automatically also shifts pointers by this amount
--            5. Call ApplyFixup to apply the fixup to all pointers
--               - resets Shift and Start to 0 after applying fixup
--
-- Port notes:   faithful port of Fixup.pm.  Perl keeps the data buffer in a
--               scalar reference and mutates it in place; the Lua analogue is
--               a carray buffer, so ApplyFixup/SetMarkerPointers take a carray
--               and the ExifTool.Set* helpers write into it in place (no
--               reassignment).  All offset arguments remain 0-based to match
--               upstream.  Byte order of each pointer is recorded at AddFixup
--               time via ExifTool.GetByteOrder().
--------------------------------------------------------------------------------

local Fixup = {}

local ExifTool = require('lexiftool')
local substr = require('lexiftool.perl').substr
local printf = require('lexiftool.perl').printf
local print = require('lexiftool.perl').print
local tsort = require('lexiftool.perl').tsort
local str = require('lexiftool.perl').str

-- New - create new Fixup object
function Fixup.new()
    local self = {}
    -- initialize required members
    self.Start = 0
    self.Shift = 0
    -- bless into the Fixup class (Lua has no package blessing; use a metatable
    -- so instances resolve methods via Fixup.<method> like upstream objects)
    return setmetatable(self, { __index = Fixup })
end

-- Clone this object
function Fixup:Clone()
    local clone = Fixup.new()
    clone.Start = self.Start
    clone.Shift = self.Shift
    local phash = self.Pointers
    if phash then
        clone.Pointers = { }
        for byteOrder, pointers in pairs(phash) do
            local copy = { }
            for i = 1, #pointers do copy[i] = pointers[i] end
            clone.Pointers[byteOrder] = copy
        end
    end
    if self.Fixups then
        clone.Fixups = { }
        for i = 1, #self.Fixups do
            clone.Fixups[i] = self.Fixups[i]:Clone()
        end
    end
    return clone
end

-- Add fixup pointer or another fixup object below this one
-- Inputs: 0) Fixup object, 1) scalar for pointer offset, or Fixup object
--         2) optional marker name for the pointer
--         3) optional pointer format ('int16u' or 'int32u', defaults to 'int32u')
function Fixup:AddFixup(pointer, marker, format)
    if type(pointer) == 'table' then
        self.Fixups = self.Fixups or { }
        self.Fixups[#self.Fixups + 1] = pointer
    else
        local byteOrder = ExifTool.GetByteOrder()
        if format then
            if format == 'int16u' then
                byteOrder = byteOrder .. '2'
            elseif format ~= 'int32u' then
                warn('Bad Fixup pointer format ' .. format)
            end
        end
        if marker then
            byteOrder = byteOrder .. '_' .. marker
        end
        local phash = self.Pointers
        if not phash then
            phash = { }
            self.Pointers = phash
        end
        if not phash[byteOrder] then
            phash[byteOrder] = { }
        end
        phash[byteOrder][#phash[byteOrder] + 1] = pointer
    end
end

-- fix up pointer offsets
-- Inputs: 0) Fixup object, 1) carray data buffer (mutated in place)
-- Returns: the data buffer (upstream mutates the referenced scalar in place;
--          the port writes into the carray in place via ExifTool.Set*)
function Fixup:ApplyFixup(dataPt)
    local start = self.Start
    local shift = self.Shift + start   -- make shift relative to start
    local phash = self.Pointers

    -- fix up pointers in this fixup
    if phash and (start ~= 0 or shift ~= 0) then
        local saveOrder = ExifTool.GetByteOrder() -- save original byte ordering
        for byteOrder, pointers in pairs(phash) do
            local prefix = substr(byteOrder, 0, 2)
            ExifTool.SetByteOrder(prefix)
            -- apply the fixup offset shift (must get as signed integer
            -- to avoid overflow in case it was negative before)
            local is16 = byteOrder:sub(3, 3) == '2'
            local get, set = is16 and ExifTool.Get16s or ExifTool.Get32s,
                              is16 and ExifTool.Set16u or ExifTool.Set32u
            for i = 1, #pointers do
                local ptr = pointers[i]
                ptr = ptr + start        -- update pointer to new start location
                pointers[i] = ptr
                if shift ~= 0 then
                    set(dataPt, ptr, get(dataPt, ptr) + shift)
                end
            end
        end
        ExifTool.SetByteOrder(saveOrder)  -- restore original byte ordering
    end
    -- recurse into contained fixups
    if self.Fixups then
        -- create our pointer hash if it doesn't exist
        phash = phash or { }
        self.Pointers = phash
        -- loop through all contained fixups
        for i = 1, #self.Fixups do
            local subFixup = self.Fixups[i]
            -- adjust the subfixup start and shift
            subFixup.Start = subFixup.Start + start
            subFixup.Shift = subFixup.Shift + shift - start
            -- recursively apply contained fixups
            dataPt = subFixup:ApplyFixup(dataPt)
            local shash = subFixup.Pointers
            if shash then
                -- add all pointers to our collapsed lists
                for byteOrder, pointers in pairs(shash) do
                    if not phash[byteOrder] then
                        phash[byteOrder] = { }
                    end
                    for j = 1, #pointers do
                        phash[byteOrder][#phash[byteOrder] + 1] = pointers[j]
                    end
                    shash[byteOrder] = nil
                end
            end
            subFixup.Pointers = nil
        end
        self.Fixups = nil    -- remove our contained fixups
    end
    -- reset our Start/Shift for the collapsed fixup
    self.Start = 0
    self.Shift = 0
    return dataPt
end

-- Is this Fixup empty?
function Fixup:IsEmpty()
    local phash = self.Pointers
    if phash then
        for _, pointers in pairs(phash) do
            if type(pointers) == 'table' and #pointers > 0 then
                return false
            end
        end
    end
    return true
end

-- Does specified marker exist?
function Fixup:HasMarker(marker)
    local phash = self.Pointers
    if phash then
        for byteOrder in pairs(phash) do
            if byteOrder:match('_' .. marker .. '$') then
                return true
            end
        end
    end
    if self.Fixups then
        for i = 1, #self.Fixups do
            if self.Fixups[i]:HasMarker(marker) then
                return true
            end
        end
    end
    return false
end

-- Set all marker pointers to specified value
-- Inputs: 0) Fixup object, 1) carray data buffer (mutated in place),
--         2) marker name, 3) pointer value, 4) offset to start of data
-- Returns: the data buffer
function Fixup:SetMarkerPointers(dataPt, marker, value, startOffset)
    local start = self.Start + (startOffset or 0)
    local phash = self.Pointers

    if phash then
        local saveOrder = ExifTool.GetByteOrder() -- save original byte ordering
        local want = '_' .. marker
        for byteOrder, pointers in pairs(phash) do
            -- (upstream: `next unless $byteOrder =~ /^(II|MM)(2?)_$marker$/`)
            local prefix = substr(byteOrder, 0, 2)
            local rest = byteOrder:sub(3)
            if (prefix == 'II' or prefix == 'MM') and (rest == want or rest == '2' .. want) then
                ExifTool.SetByteOrder(prefix)
                local set = rest ~= want and ExifTool.Set16u or ExifTool.Set32u
                for i = 1, #pointers do
                    set(dataPt, pointers[i] + start, value)
                end
            end
        end
        ExifTool.SetByteOrder(saveOrder)  -- restore original byte ordering
    end
    if self.Fixups then
        for i = 1, #self.Fixups do
            dataPt = self.Fixups[i]:SetMarkerPointers(dataPt, marker, value, start)
        end
    end
    return dataPt
end

-- Get pointer values for specified marker
-- Inputs: 0) Fixup object, 1) data buffer, 2) marker name, 3) offset to start
-- Returns: table of marker pointers (upstream returns list in list context)
function Fixup:GetMarkerPointers(dataPt, marker, startOffset)
    local start = self.Start + (startOffset or 0)
    local phash = self.Pointers
    local pointers = { }

    if phash then
        local saveOrder = ExifTool.GetByteOrder()
        local want = '_' .. marker
        for byteOrder, ptrs in pairs(phash) do
            -- (upstream: `grep /_$marker$/, keys %$phash`)
            if byteOrder:sub(-#want) == want then
                ExifTool.SetByteOrder(substr(byteOrder,0,2))
                local prefix = substr(byteOrder, 0, 3)
                local get = (prefix == 'II2' or prefix == 'MM2') and ExifTool.Get16u or ExifTool.Get32u
                for i = 1, #ptrs do
                    pointers[#pointers + 1] = get(dataPt, ptrs[i] + start)
                end
            end
        end
        ExifTool.SetByteOrder(saveOrder)
    end
    if self.Fixups then
        for i = 1, #self.Fixups do
            local sub = self.Fixups[i]:GetMarkerPointers(dataPt, marker, start)
            for j = 1, #sub do
                pointers[#pointers + 1] = sub[j]
            end
        end
    end
    return pointers
end

-- Dump fixup to console for debugging
function Fixup:Dump(indent)
    indent = indent or ''
    printf(io.stdout, indent .. "Fixup start=0x%x shift=0x%x\n", self.Start, self.Shift)
    local phash = self.Pointers
    if phash then
        local keys = { }
        for k in pairs(phash) do keys[#keys + 1] = k end
        tsort(keys)
        for i = 1, #keys do
            local byteOrder = keys[i]
            local strs = { }
            for j = 1, #phash[byteOrder] do
                strs[#strs + 1] = str(phash[byteOrder][j])
            end
            print(io.stdout, indent .. '  ' .. byteOrder .. ': ', table.concat(strs, ' '), "\n")
        end
    end
    if self.Fixups then
        for i = 1, #self.Fixups do
            self.Fixups[i]:Dump(indent .. '  ')
        end
    end
end

return Fixup
