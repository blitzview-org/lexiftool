--------------------------------------------------------------------------------
-- File:         lexiftool/JVC.lua
-- Ported from:  lib/Image/ExifTool/JVC.pm
--
-- Description:  JVC EXIF maker notes tags
--
-- Revisions:    12/21/2005  - P. Harvey Created
--
-- Port notes:   read subset: the Main and Text tables plus ProcessJVCText.
--               Deferred: the write path (upstream sets WRITE_PROC to
--               Exif::WriteExif for the binary Main table).
--------------------------------------------------------------------------------

local ExifTool = require('lexiftool')
local perlTruthy = require('lexiftool.perl').truthy
local matches = require('lexiftool.perl').matches
local eachMatch = require('lexiftool.perl').eachMatch
local str = require('lexiftool.perl').str

local JVC = {}

JVC.Main = {
    WRITE_PROC = function(...) return require('lexiftool.WriteExif').WriteExif(...) end,
    CHECK_PROC = function(...) return require('lexiftool.WriteExif').CheckExif(...) end,
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'JVC EXIF maker note tags.',
    -- 0x0001 - almost always '2', but '3' for GR-DV700 samples
    [0x0002] = {
        Name = 'CPUVersions',
        -- remove trailing nulls/spaces and split at remaining nulls/spaces
        ValueConv = function(_self, val)
            -- upstream: `s/(\s*\0)+$//; s/(\s*\0)+/, /g;` -- Lua patterns
            -- can't repeat a captured group ("(\s*\0)+"), so this collapses
            -- whitespace immediately preceding a null into the null first
            -- (leaving only runs of bare nulls), then handles those runs
            -- with plain (unparenthesized, so `+`-able) null-only patterns
            local s = str(val):gsub('[ \t\n\r\f\v]+\0', '\0')
            s = s:gsub('\0+$', '')
            s = s:gsub('\0+', ', ')
            return s
        end,
    },
    [0x0003] = {
        Name = 'Quality',
        PrintConv = { [0] = 'Low', [1] = 'Normal', [2] = 'Fine' },
    },
}

-- JVC text-based maker notes
JVC.Text = {
    GROUPS = { [0] = 'MakerNotes', [2] = 'Camera' },
    NOTES = 'JVC/Victor text-based maker note tags.',
    VER = { Name = 'MakerNoteVersion' }, -- PH
    QTY = { -- PH
        Name = 'Quality',
        PrintConv = { STND = 'Normal', STD = 'Normal', FINE = 'Fine' },
    },
}

--------------------------------------------------------------------------------
-- Process JVC text-based maker notes
-- Inputs: 0) ExifTool object reference, 1) dirInfo, 2) tag table for this directory
-- Returns: 1 on success, otherwise returns 0 and sets a Warning
function JVC.ProcessJVCText(et, dirInfo, tagTablePtr)
    local dataPt = dirInfo.DataPt
    local dirStart = dirInfo.DirStart or 0
    local dataLen = dirInfo.DataLen
    local dirLen = dirInfo.DirLen or (dataLen - dirStart)

    local data = dataPt:sub(dirStart + 1, dirStart + dirLen)
    -- validate text maker notes
    if not matches(data, [[^VER:]]) then
        et:Warn('Bad JVC text maker notes')
        return 0
    end
    for tag, val in eachMatch(data, [[(?s)([A-Z]+):(.{3,4})]]) do
        local tagInfo = et:GetTagInfo(tagTablePtr, tag)
        if perlTruthy(et.OPTIONS.Verbose) then
            et:VerboseInfo(tag, tagInfo, { Table = tagTablePtr, Value = val })
        end
        if not tagInfo then
            local unknown = et.OPTIONS.Unknown
            if not perlTruthy(unknown) then
                goto continue
            end
            tagInfo = {
                Name = 'JVC_Text_' .. tag,
                Unknown = 1,
                PrintConv = function(self, v) return ExifTool.LimitLongValues(v, self) end,
            }
            et:AddTagToTable(tagTablePtr, tag, tagInfo)
        end
        et:FoundTag(tagInfo, val)
        ::continue::
    end
    return 1
end

JVC.Text.PROCESS_PROC = JVC.ProcessJVCText

return JVC
