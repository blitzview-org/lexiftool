--------------------------------------------------------------------------------
-- File:         lexiftool/Scalado.lua
-- Ported from:  lib/Image/ExifTool/Scalado.pm
--
-- Description:  Read APP4 SCALADO metadata
--
-- Revisions:    2013-09-13 - P. Harvey Created
--
-- Port notes:   ported in full: the `Main` table and `ProcessScalado`.
--               Upstream Scalado.pm is read-only.
--               No vendored test image carries an APP4 SCALADO segment.
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perl = require('lexiftool.perl')
local substr = perl.substr
local perlTruthy = ExifTool.perlTruthy

local Scalado = {}

-- JPEG APP4 SCALADO tags
Scalado.Main = {
    GROUPS = { [0] = 'APP4', [1] = 'Scalado', [2] = 'Image' },
    PROCESS_PROC = false, -- predeclaration, see below for implementation
    TAG_PREFIX = 'Scalado',
    FORMAT = 'int32s',
    NOTES = [[
        Tags extracted from the JPEG APP4 "SCALADO" segment found in images from
        HTC, LG and Samsung phones.  (Presumably written by Scalado mobile software,
        L<http://www.scalado.com/>.)
    ]],
    SPMO = {
        Name = 'DataLength',
        Unknown = 1,
    },
    WDTH = {
        Name = 'PreviewImageWidth',
        ValueConv = function(_self, val) return perlTruthy(val) and math.abs(val) or nil end,
    },
    HGHT = {
        Name = 'PreviewImageHeight',
        ValueConv = function(_self, val) return perlTruthy(val) and math.abs(val) or nil end,
    },
    QUAL = {
        Name = 'PreviewQuality',
        ValueConv = function(_self, val) return perlTruthy(val) and math.abs(val) or nil end,
    },
    -- tags not yet decoded with observed values:
    -- CHKH: 0, various negative values
    -- CHKL: various negative values
    -- CLEN: -1024
    -- CSPC: -2232593
    -- DATA: (+ve data length)
    -- HDEC: 0
    -- MAIN: 0, 60
    -- META: 24
    -- SCI0: (+ve data length) often 36
    -- SCI1: (+ve data length) 36
    -- SCX0: (+ve data length)
    -- SCX1: (+ve data length) often 84
    -- WDEC: 0
    -- VERS: -131328
}

--------------------------------------------------------------------------------
-- Extract information from the JPEG APP4 SCALADO segment
-- Inputs: 0) ExifTool object ref, 1) dirInfo ref, 2) tag table ref
-- Returns: 1 on success
function Scalado.ProcessScalado(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local pos = 0
    local end_ = #dataPt
    local unknown = et:Options('Unknown')

    et:VerboseDir('APP4 SCALADO', nil, end_)
    ExifTool.SetByteOrder('MM')

    while true do
        if pos + 12 > end_ then break end
        local tag = substr(dataPt, pos, 4)
        local ver = ExifTool.Get32u(dataPt, pos + 4) -- (looks like a version for some tags)
        if not tagTablePtr[tag] and perlTruthy(unknown) then
            local name = tag
            name = name:gsub('[^%-A-Za-z0-9_]', '')
            if #name == 0 then break end   -- stop if tag is garbage
            et:AddTagToTable(tagTablePtr, tag, {
                Name = 'Scalado_' .. name,
                Description = 'Scalado ' .. name,
                Unknown = 1,
            })
        end
        et:HandleTag(tagTablePtr, tag, nil, {
            DataPt  = dataPt,
            Start   = pos + 8,
            Size    = 4,
            Extra   = ', ver ' .. ExifTool.NumStr(ver),
        })
        if tag == 'SPMO' then
            local val = ExifTool.Get32u(dataPt, pos + 8)
            if ver < 5 then -- (I don't have samples for version 3 or 4, so I'm not sure about these)
                end_ = end_ - val     -- SPMO gives trailer data length
            else
                end_ = val + 12       -- SPMO gives length of Scalado directory (excepting this entry)
            end
        end
        pos = pos + 12
    end
    return 1
end

Scalado.Main.PROCESS_PROC = Scalado.ProcessScalado

return Scalado
